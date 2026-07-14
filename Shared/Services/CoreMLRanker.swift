import CryptoKit
import Foundation
import CoreML

/// Option 1 of the ranker A/B: a Core ML **learning-to-rank** strategy trained
/// on the app's own feedback logs (`FaceOffLog`/`PreferenceLog`) plus a weak-
/// label bootstrap. See `Tooling/CoreMLLTR/` for the Python training pipeline.
///
/// It mirrors `AIPrioritizer`'s two-axis design exactly, only swapping the
/// **importance** source:
///
/// - **Importance** (real-world stakes): a bundled Core ML model scores each
///   reminder from content-only features — priority flag, notes presence,
///   title length, and a hashed list identity. Date-blind, like the Apple
///   path's importance classification, so timing never leaks into it.
/// - **Time urgency**: `UrgencyScorer.timeUrgency` deterministically from the
///   dates at rank time, combined with the learned importance using the same
///   0.55/0.45 split the heuristic uses (via `UrgencyScorer.score` on the tier
///   the model score maps to). With `consideringDueDates` off, importance
///   alone orders the list.
///
/// The loaded `MLModel` is cached in static storage (`Self.model`) because the
/// factory builds a fresh `CoreMLRanker` per rank. If the model is missing or
/// fails to load, `availability` is `.unavailable(...)` and ranking falls back
/// to the pure `UrgencyScorer` heuristic ordering — never crashes, never blocks.
///
/// ── FEATURE SCHEMA (must stay in lockstep with Tooling/CoreMLLTR/features.py) ──
/// The model input "features" is an MLMultiArray of `featureCount` floats:
///   [0] priority_high    1 if RFC-5545 priority 1..4
///   [1] priority_medium  1 if priority == 5
///   [2] priority_low     1 if priority 6..9
///   [3] priority_none    1 if priority 0 / unset
///   [4] has_notes        1 if non-empty notes
///   [5] title_len_norm   min(title.count, 100) / 100
///   [6] title_words_norm min(wordCount(title), 20) / 20
///   [7] notes_len_norm   min(notes.count, 140) / 140
///   [8..8+buckets) list identity one-hot over `listHashBuckets` md5 buckets
///   [16..16+32)    TitleEmbedding vector — the semantic title signal
///                  (NLEmbedding → seeded 32-dim projection, L2-normalized);
///                  zeros when embedding assets are unavailable. Added after
///                  held-out evaluation showed ~half of real face-off pairs
///                  are same-list + same-priority, invisible to the features
///                  above.
/// Output "score" is a scalar raw importance (higher = more important); we
/// squash it through a sigmoid into the [0,1] importance weight.
struct CoreMLRanker: Ranker {
    // MARK: Schema constants (keep identical to features.py)

    /// Number of md5 buckets the list name is hashed into (LIST_HASH_BUCKETS).
    static let listHashBuckets = 8
    /// Total feature vector length (FEATURE_COUNT = 8 dense + buckets + embedding).
    static let featureCount = 8 + listHashBuckets + TitleEmbedding.dimension

    /// Name of the bundled model resource (without extension).
    private static let modelResourceName = "ImportanceRanker"

    // MARK: Model loading (cached; the factory builds a fresh instance per rank)

    /// Loaded once, lazily, and shared. `nil` if the model isn't bundled or
    /// fails to compile/load — the ranker then behaves as the pure heuristic.
    /// `nonisolated(unsafe)`: immutable after load, and `MLModel.prediction`
    /// is documented thread-safe, so concurrent reads are fine even though
    /// `MLModel` isn't `Sendable`.
    nonisolated(unsafe) private static let model: MLModel? = loadModel()

    private static func loadModel() -> MLModel? {
        // An .mlpackage bundled as a resource is compiled to .mlmodelc at build
        // time; look for the compiled form first, then fall back to compiling
        // an .mlpackage on the fly (e.g. if only the package was copied in).
        let bundle = Bundle(for: BundleToken.self)
        if let compiled = bundle.url(forResource: modelResourceName, withExtension: "mlmodelc") {
            return try? MLModel(contentsOf: compiled)
        }
        if let package = bundle.url(forResource: modelResourceName, withExtension: "mlpackage"),
           let compiled = try? MLModel.compileModel(at: package) {
            return try? MLModel(contentsOf: compiled)
        }
        return nil
    }

    /// Anchor class so `Bundle(for:)` resolves to the framework/app bundle that
    /// actually contains the Shared resources, on both iOS and macOS.
    private final class BundleToken {}

    // MARK: Ranker conformance

    var availability: AIAvailability {
        Self.model == nil
            ? .unavailable("The Core ML ranking model isn't bundled. Using basic sorting for now.")
            : .available
    }

    func rank(_ items: [ReminderItem], consideringDueDates: Bool = true) async -> [ReminderItem] {
        guard !items.isEmpty else { return [] }
        let now = Date()

        // Learned importance per item, or the priority-flag fallback tier when
        // the model is unavailable — mirrors AIPrioritizer's fallback path.
        let importanceWeights: [String: Double]
        if let model = Self.model {
            importanceWeights = Self.predictImportance(items, model: model)
        } else {
            importanceWeights = [:]
        }

        let scored = items.map { item -> ReminderItem in
            let combined: Double
            if let learned = importanceWeights[item.id] {
                // Reuse UrgencyScorer's exact axis combination, feeding the
                // learned [0,1] importance weight in place of a tier weight, so
                // the time term and 0.55/0.45 split match the heuristic path.
                combined = Self.combinedScore(
                    importanceWeight: learned,
                    item: item,
                    now: now,
                    consideringDueDates: consideringDueDates
                )
            } else {
                combined = Double(UrgencyScorer.score(
                    importance: UrgencyScorer.fallbackImportance(for: item),
                    item: item,
                    now: now,
                    consideringDueDates: consideringDueDates
                ))
            }
            return item.withScore(Int(combined.rounded()))
        }

        return Self.sortRanked(scored, originalOrder: items)
    }

    // MARK: Scoring

    /// Combines a learned [0,1] importance weight with the deterministic time
    /// axis using the same weights and formula as `UrgencyScorer.score`, so
    /// this ranker sits on the same 0-100 scale as the Apple baseline.
    static func combinedScore(
        importanceWeight: Double,
        item: ReminderItem,
        now: Date,
        consideringDueDates: Bool
    ) -> Double {
        let timeWeight = 0.55
        let importanceAxisWeight = 0.45
        let combined: Double
        if consideringDueDates {
            combined = timeWeight * UrgencyScorer.timeUrgency(for: item, now: now)
                + importanceAxisWeight * importanceWeight
        } else {
            combined = importanceWeight
        }
        return (combined * 100).rounded()
    }

    /// Runs the model over every item, returning id -> [0,1] importance weight
    /// (sigmoid of the raw linear score). Items that fail prediction are simply
    /// omitted, so the caller applies the priority-flag fallback for them.
    private static func predictImportance(_ items: [ReminderItem], model: MLModel) -> [String: Double] {
        var result: [String: Double] = [:]
        result.reserveCapacity(items.count)
        for item in items {
            guard let raw = rawScore(for: item, model: model) else { continue }
            result[item.id] = 1.0 / (1.0 + exp(-raw))
        }
        return result
    }

    private static func rawScore(for item: ReminderItem, model: MLModel) -> Double? {
        guard let array = try? MLMultiArray(shape: [NSNumber(value: featureCount)], dataType: .float32) else {
            return nil
        }
        let feats = features(for: item)
        for (index, value) in feats.enumerated() {
            array[index] = NSNumber(value: Float(value))
        }
        guard let provider = try? MLDictionaryFeatureProvider(dictionary: ["features": array]),
              let output = try? model.prediction(from: provider),
              let scoreValue = output.featureValue(for: "score") else {
            return nil
        }
        if let scoreArray = scoreValue.multiArrayValue, scoreArray.count > 0 {
            return scoreArray[0].doubleValue
        }
        return scoreValue.doubleValue
    }

    // MARK: Feature extraction (LOCKSTEP with Tooling/CoreMLLTR/features.py)

    /// The `featureCount`-length feature vector for one reminder. Any change
    /// here must be mirrored in `features.py` and the model retrained.
    static func features(for item: ReminderItem) -> [Double] {
        var feats: [Double] = []
        feats.reserveCapacity(featureCount)

        // Priority one-hot (mirrors ReminderPriorityLevel(rawPriority:)).
        let p = item.rawPriority
        let high = (1...4).contains(p)
        let medium = p == 5
        let low = (6...9).contains(p)
        let none = !(high || medium || low)
        feats.append(high ? 1 : 0)
        feats.append(medium ? 1 : 0)
        feats.append(low ? 1 : 0)
        feats.append(none ? 1 : 0)

        let notes = item.notes ?? ""
        let title = item.title
        feats.append(notes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? 0 : 1)
        feats.append(Double(min(title.count, 100)) / 100.0)
        feats.append(Double(min(wordCount(title), 20)) / 20.0)
        feats.append(Double(min(notes.count, 140)) / 140.0)

        var buckets = [Double](repeating: 0, count: listHashBuckets)
        buckets[listBucket(item.listName)] = 1
        feats.append(contentsOf: buckets)

        // Semantic title vector — computed by the same TitleEmbedding code
        // the training pipeline shells out to (Tooling/EmbedTool), so the
        // two sides can't drift.
        feats.append(contentsOf: TitleEmbedding.vector(for: title))

        return feats
    }

    /// Whitespace-split non-empty word count, matching Python's `str.split()`.
    private static func wordCount(_ text: String) -> Int {
        text.split(whereSeparator: { $0.isWhitespace }).count
    }

    /// Stable md5 hash of the list name into [0, listHashBuckets), matching
    /// `features._list_bucket`: first 4 bytes of the md5 digest, big-endian,
    /// mod buckets. An empty list name maps to bucket 0.
    static func listBucket(_ listName: String) -> Int {
        guard !listName.isEmpty else { return 0 }
        let digest = Insecure.MD5.hash(data: Data(listName.utf8))
        let bytes = Array(digest)
        let value = (UInt32(bytes[0]) << 24) | (UInt32(bytes[1]) << 16)
            | (UInt32(bytes[2]) << 8) | UInt32(bytes[3])
        return Int(value % UInt32(listHashBuckets))
    }

    // MARK: Sorting (same tie-breaking as AIPrioritizer.sortRanked)

    private static func sortRanked(_ scored: [ReminderItem], originalOrder: [ReminderItem]) -> [ReminderItem] {
        let originalIndex = Dictionary(uniqueKeysWithValues: originalOrder.enumerated().map { ($1.id, $0) })
        return scored.sorted { a, b in
            let scoreA = a.score ?? 0
            let scoreB = b.score ?? 0
            if scoreA != scoreB { return scoreA > scoreB }
            switch (a.dueDate, b.dueDate) {
            case let (dueA?, dueB?) where dueA != dueB:
                return dueA < dueB
            case (.some, .none):
                return true
            case (.none, .some):
                return false
            default:
                return (originalIndex[a.id] ?? .max) < (originalIndex[b.id] ?? .max)
            }
        }
    }
}
