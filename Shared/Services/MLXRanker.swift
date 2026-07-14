import Foundation

// MLX runs only on Apple Silicon. The x86_64 iOS-simulator slice and any
// non-Apple-Silicon target cannot link the MLX metal kernels, so the whole
// dependency is compiled out there and the ranker degrades to a pure
// deterministic (`UrgencyScorer`) ordering. `project.yml` also excludes the
// x86_64 simulator arch so the app still builds; this guard is the code-level
// counterpart, keeping the baseline (non-MLX) code paths compiling on slices
// where MLX can't link.
#if canImport(MLXLLM) && canImport(MLXLMCommon) && arch(arm64) && !SORTED_TESTS
import MLXLLM
import MLXLMCommon
import MLX
#if canImport(Metal)
import Metal
#endif
#endif

/// The user's choice of which open LLM the MLX big-batch ranker runs
/// (Settings → Experimental → MLX model). Curated hub ids only — 4-bit
/// quantized instruct models known to work with MLX Swift on-device.
/// Persisted straight to UserDefaults (see `defaultsKey`) so both the
/// main-actor `AppSettings` and the nonisolated rank path read one source
/// of truth without actor hops. Switching models re-downloads on first use
/// (each is a one-time few-hundred-MB to ~2GB fetch, cached by the hub
/// loader).
enum MLXModelChoice: String, CaseIterable, Sendable {
    case qwen1_5B
    case llama1B
    case qwen3B

    static let defaultsKey = "Sorted.settings.mlxModel"

    /// The persisted choice, defaulting to the balanced Qwen 1.5B.
    static var current: MLXModelChoice {
        UserDefaults.standard.string(forKey: defaultsKey)
            .flatMap(MLXModelChoice.init) ?? .qwen1_5B
    }

    var hubID: String {
        switch self {
        case .qwen1_5B: "mlx-community/Qwen2.5-1.5B-Instruct-4bit"
        case .llama1B: "mlx-community/Llama-3.2-1B-Instruct-4bit"
        case .qwen3B: "mlx-community/Qwen2.5-3B-Instruct-4bit"
        }
    }

    var displayName: String {
        switch self {
        case .qwen1_5B: "Qwen 2.5 1.5B (balanced)"
        case .llama1B: "Llama 3.2 1B (fastest)"
        case .qwen3B: "Qwen 2.5 3B (best, most memory)"
        }
    }

    var detail: String {
        switch self {
        case .qwen1_5B:
            "Good ranking quality at a size comfortable on modern Apple-Silicon Macs and phones. ~1GB download."
        case .llama1B:
            "Smallest and fastest, lowest memory use; noticeably weaker comparative judgment. ~700MB download."
        case .qwen3B:
            "Strongest comparative ranking, but ~2GB and slower — best on a Mac or high-end device."
        }
    }
}

/// Option 2 of the ranking A/B: a bigger-context on-device open LLM run via
/// MLX Swift, so a **single large comparative pass** (default 40 reminders)
/// judges the whole group side by side. This restores the signal Matt found
/// best — the app ranked most usefully when the model weighed a big batch
/// together — which Apple's ~4096-token FoundationModels context forced away
/// (see `AIPrioritizer.batchSize = 15`).
///
/// Design mirrors `AIPrioritizer.listwiseOrder`: reminders are labelled with
/// short tokens `R0..Rn`, due/creation dates are **pre-computed in Swift** to
/// relative offsets (small models are unreliable at date math, so we never ask
/// the model to do it), and the model is asked to emit every token exactly
/// once, most-important-first. The reply is parsed back to ids; anything
/// omitted or duplicated falls back to the deterministic `UrgencyScorer` order
/// for the remainder, exactly as `AIPrioritizer.reorderTop` rebuilds.
///
/// The loaded model lives in static storage (`ModelStore`) so the fresh
/// instance the factory builds per rank reuses the one download/load.
///
/// Note on `SORTED_TESTS`: the standalone logic-test bundle compiles this file
/// (for its pure prompt/parse helpers) without the FoundationModels-backed
/// `Ranker`/`AIAvailability` types or the app's caches. That flag drops just
/// the protocol conformance and `availability`/`rank` glue, leaving every pure
/// static function under test intact.
struct MLXRanker {
    /// Big comparative batch. The whole point of this arm: judge a large group
    /// together rather than the 15-item chunks the Apple context forced.
    /// Batches larger than this are ranked in successive passes, each pass
    /// re-anchored by the deterministic pre-sort so the most important items
    /// land in the first (highest-signal) pass.
    static let batchSize = 40

    /// The batch is sized to the model's judgment capacity, not just its
    /// context window: the 1B model degrades sharply when asked to hold a
    /// 40-way comparison, emitting partial orderings whose omitted items
    /// silently fall back to the heuristic order — a mostly-deterministic
    /// list wearing the MLX label. A smaller group it can actually judge
    /// beats a bigger one it can't.
    static func batchSize(for choice: MLXModelChoice) -> Int {
        switch choice {
        case .llama1B: 20
        case .qwen1_5B, .qwen3B: batchSize
        }
    }

    /// The hub id of the user's chosen model (Settings → Experimental → MLX
    /// model), read straight from UserDefaults so the nonisolated rank path
    /// never has to hop to the main-actor `AppSettings`.
    static var modelID: String { MLXModelChoice.current.hubID }

    /// Deterministic generation (temperature 0) so the same reminder set yields
    /// the same ordering call to call — the `Ranker` contract asks for a pure,
    /// diffable ordering. Token budget is generous enough for `batchSize`
    /// tokens plus separators but bounded so a run-away decode can't hang.
    private static let maxTokens = 512

    #if !SORTED_TESTS
    static var availability: AIAvailability {
        #if os(macOS)
        let device = "Mac"
        #else
        let device = "device"
        #endif

        #if canImport(MLXLLM) && canImport(MLXLMCommon) && arch(arm64) && !SORTED_TESTS
        // If a previous load already failed for a knowable reason, surface it.
        if let message = ModelStore.shared.lastUnavailableMessage {
            return .unavailable(message)
        }
        if ModelStore.shared.loadedHubID == Self.modelID {
            return .available
        }
        // Not yet loaded: the first rank kicks off the one-time download/load
        // in the background and uses basic sorting meanwhile (ModelStore never
        // blocks a rank on the fetch), so tell the user what they're seeing.
        return .unavailable(
            "The MLX model downloads on first use and loads in the background. Using basic sorting until it's ready.")
        #else
        return .unavailable(
            "The MLX big-batch ranker needs an Apple-Silicon \(device); this build can't run it. Using basic sorting.")
        #endif
    }

    /// Ranks all items most- to least-important. Deterministically pre-sorts
    /// with `UrgencyScorer` (so the first big-batch pass gets the highest-stakes
    /// items and so we have a fallback order), then runs the MLX comparative
    /// pass over the leading batch(es). Falls back cleanly to the deterministic
    /// order whenever MLX is unavailable or a pass fails/omits items.
    func rank(_ items: [ReminderItem], consideringDueDates: Bool = true) async -> [ReminderItem] {
        guard !items.isEmpty else { return [] }

        let now = Date()
        let preSorted = Self.deterministicOrder(items, consideringDueDates: consideringDueDates, now: now)

        #if canImport(MLXLLM) && canImport(MLXLMCommon) && arch(arm64) && !SORTED_TESTS
        guard let container = await ModelStore.shared.container() else {
            return preSorted
        }

        var ordered: [ReminderItem] = []
        var seen: Set<String> = []
        // Process in big batches. In practice a reminder set is usually one
        // batch; larger sets get successive passes, each already anchored by
        // the deterministic pre-sort.
        let batchSize = Self.batchSize(for: MLXModelChoice.current)
        for start in stride(from: 0, to: preSorted.count, by: batchSize) {
            let chunk = Array(preSorted[start..<min(start + batchSize, preSorted.count)])
            let orderedIDs = await Self.listwiseOrder(
                chunk, container: container, includeDates: consideringDueDates, now: now)
            let rebuilt = Self.reorder(chunk, byIDs: orderedIDs)
            for item in rebuilt where seen.insert(item.id).inserted {
                ordered.append(item)
            }
        }
        // Safety net: append anything not emitted (shouldn't happen).
        for item in preSorted where seen.insert(item.id).inserted {
            ordered.append(item)
        }

        // Reassign the deterministic scores in the new order so displayed
        // scores stay monotonically decreasing down the list, mirroring
        // `AIPrioritizer.reorderTop`.
        let slotScores = preSorted.map { $0.score ?? 0 }
        return zip(ordered, slotScores).map { $0.withScore($1) }
        #else
        return preSorted
        #endif
    }
    #endif

    // MARK: - Deterministic ordering & fallback

    /// The `UrgencyScorer`-based ordering used both as the pre-sort that anchors
    /// batches and as the fallback whenever the model can't run or omits items.
    /// No AI importance is available in this arm's fallback, so importance is
    /// derived from the priority flag exactly like `AIPrioritizer`'s fallback.
    static func deterministicOrder(
        _ items: [ReminderItem],
        consideringDueDates: Bool,
        now: Date
    ) -> [ReminderItem] {
        let scored = items.map { item -> ReminderItem in
            let tier = UrgencyScorer.fallbackImportance(for: item)
            return item.withScore(UrgencyScorer.score(
                importance: tier,
                item: item,
                now: now,
                consideringDueDates: consideringDueDates
            ))
        }
        let originalIndex = Dictionary(uniqueKeysWithValues: items.enumerated().map { ($1.id, $0) })
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

    // MARK: - Prompt construction & parsing (pure, unit-tested)

    /// Builds the listwise prompt lines and the token→id map for a batch.
    /// Extracted as a pure function so prompt construction is testable without
    /// the model. Mirrors `AIPrioritizer.listwiseOrder`'s line format:
    /// `[R0] title="…" list="…" notes="…"` plus, when dates are included,
    /// ` due=… created=…` as app-computed relative offsets.
    static func buildPrompt(
        for batch: [ReminderItem],
        includeDates: Bool,
        now: Date
    ) -> (instructions: String, prompt: String, tokenToID: [String: String]) {
        var tokenToID: [String: String] = [:]
        let lines = batch.enumerated().map { index, item -> String in
            let token = "R\(index)"
            tokenToID[token] = item.id
            var line = formatLine(token: token, item: item)
            if includeDates {
                line += " due=\(relativeDayDescription(for: item.dueDate, now: now, pastPrefix: "overdue by", pastSuffix: "", futurePrefix: "in", noneValue: "none"))"
                if let created = item.creationDate {
                    line += " created=\(relativeDayDescription(for: created, now: now, pastPrefix: "", pastSuffix: "ago", futurePrefix: "in", noneValue: "unknown"))"
                }
            }
            return line
        }

        let timingClause = includeDates
            ? "Weigh real-world stakes and timing together: due dates and "
                + "creation dates are given as relative offsets from today, "
                + "already computed by the app — use them directly."
            : "Judge by real-world stakes alone — what each task is, not when."

        let instructions = """
        You order a person's reminders (to-dos) by which deserves attention \
        first, judging all of them together as a group. \(timingClause) \
        Respond with ONLY the tokens (e.g. R0 R3 R1), most important first, \
        separated by spaces, each token exactly once, and nothing else — no \
        commentary, numbering, or punctuation.
        """

        let prompt = "Order these reminders, most important first:\n"
            + lines.joined(separator: "\n")
            + "\n\nOutput every token (\(batch.indices.map { "R\($0)" }.joined(separator: " "))) "
            + "exactly once, most important first, space-separated."

        return (instructions, prompt, tokenToID)
    }

    /// Parses raw model output back into reminder ids. Unlike the baseline's
    /// `@Generable` structured decode, an open model emits free text, so we
    /// scan for `R<number>` tokens in order, map each to its id via
    /// `tokenToID`, and drop unknown or duplicate tokens. Extracted and pure so
    /// parsing is unit-tested without the model.
    static func parseOrder(_ output: String, tokenToID: [String: String]) -> [String] {
        var ids: [String] = []
        var seenTokens: Set<String> = []
        // Match R followed by digits, as whole tokens (bounded by non-word
        // chars) so "R12" isn't split and words like "Rank" don't match.
        let scanner = output as NSString
        let pattern = "R[0-9]+"
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let matches = regex.matches(in: output, range: NSRange(location: 0, length: scanner.length))
        for match in matches {
            let token = scanner.substring(with: match.range)
            guard let id = tokenToID[token], seenTokens.insert(token).inserted else { continue }
            ids.append(id)
        }
        return ids
    }

    /// Rebuilds a batch in the model's id order; items the model omitted or
    /// duplicated keep their prior (deterministic) relative position at the end
    /// of the batch — mirrors `AIPrioritizer.reorderTop`.
    static func reorder(_ batch: [ReminderItem], byIDs orderedIDs: [String]) -> [ReminderItem] {
        let byID = Dictionary(uniqueKeysWithValues: batch.map { ($0.id, $0) })
        var result: [ReminderItem] = []
        var seen: Set<String> = []
        for id in orderedIDs {
            if let item = byID[id], seen.insert(id).inserted {
                result.append(item)
            }
        }
        for item in batch where seen.insert(item.id).inserted {
            result.append(item)
        }
        return result
    }

    /// Content only — no due date, creation date, or priority flag inline;
    /// dates are appended separately when enabled. Same format and 140-char
    /// notes cap as `AIPrioritizer.formatLine`.
    static func formatLine(token: String, item: ReminderItem) -> String {
        var parts = ["[\(token)]", "title=\"\(item.title)\"", "list=\"\(item.listName)\""]
        if let notes = item.notes, !notes.isEmpty {
            let trimmed = notes.count > 140 ? String(notes.prefix(140)) + "…" : notes
            parts.append("notes=\"\(trimmed)\"")
        }
        return parts.joined(separator: " ")
    }

    /// App-computed relative date description, identical to
    /// `AIPrioritizer.relativeDayDescription` — on-device models are unreliable
    /// at date arithmetic, so the app does it and hands the model a phrase.
    static func relativeDayDescription(
        for date: Date?,
        now: Date,
        pastPrefix: String,
        pastSuffix: String,
        futurePrefix: String,
        noneValue: String
    ) -> String {
        guard let date else { return noneValue }
        let calendar = Calendar.current
        let days = calendar.dateComponents(
            [.day],
            from: calendar.startOfDay(for: now),
            to: calendar.startOfDay(for: date)
        ).day ?? 0
        if days == 0 { return "today" }
        let magnitude = abs(days)
        let unit = "day\(magnitude == 1 ? "" : "s")"
        if days < 0 {
            let words = [pastPrefix, "\(magnitude) \(unit)", pastSuffix].filter { !$0.isEmpty }
            return words.joined(separator: " ")
        } else {
            return "\(futurePrefix) \(magnitude) \(unit)"
        }
    }
}

#if !SORTED_TESTS
extension MLXRanker: Ranker {
    /// This arm's availability is the MLX model's readiness (see the static
    /// property), exposed per-instance so it reaches through the protocol —
    /// same pattern as `AIPrioritizer`.
    var availability: AIAvailability { Self.availability }
}
#endif

#if canImport(MLXLLM) && canImport(MLXLMCommon) && arch(arm64) && !SORTED_TESTS
extension MLXRanker {
    /// One MLX comparative pass over a batch. Builds the prompt, runs the
    /// model, parses the reply to ids. Returns an empty array on any failure so
    /// the caller falls back to the deterministic order.
    static func listwiseOrder(
        _ batch: [ReminderItem],
        container: ModelContainer,
        includeDates: Bool,
        now: Date
    ) async -> [String] {
        let (instructions, prompt, tokenToID) = buildPrompt(
            for: batch, includeDates: includeDates, now: now)
        do {
            let session = ChatSession(
                container,
                instructions: instructions,
                generateParameters: GenerateParameters(maxTokens: maxTokens, temperature: 0))
            let output = try await session.respond(to: prompt)
            let ids = parseOrder(output, tokenToID: tokenToID)
            #if DEBUG
            // Coverage is the tell when a small model "looks bad": every
            // omitted token silently keeps its deterministic position, so low
            // coverage means the displayed order is mostly heuristic, not the
            // model judging poorly. Watch this in Xcode's console.
            print("MLXRanker[\(MLXModelChoice.current.rawValue)]: ordered \(ids.count)/\(batch.count) of batch")
            #endif
            return ids
        } catch {
            #if DEBUG
            print("MLXRanker[\(MLXModelChoice.current.rawValue)]: pass failed — \(error)")
            #endif
            return []
        }
    }
}

/// Holds the loaded MLX model across ranks. The factory builds a fresh
/// `MLXRanker` per rank (per the `Ranker` contract), so the expensive
/// download/load must live here in shared static storage, loaded once.
actor ModelStore {
    static let shared = ModelStore()

    private var loadedContainer: ModelContainer?
    private var loadTask: Task<ModelContainer?, Never>?

    /// Best-effort state for availability reporting from a synchronous
    /// context. nonisolated(unsafe) is acceptable: they're plain reads for a
    /// UI hint, and a stale value only affects an advisory message, never
    /// correctness. `loadedHubID` (not a bool) so switching the model in
    /// Settings correctly reads as "not ready yet" until the new one loads.
    nonisolated(unsafe) private(set) var loadedHubID: String?
    nonisolated(unsafe) private(set) var lastUnavailableMessage: String?

    /// Returns the loaded container if it's ready, **without ever waiting for
    /// the load** — the first call kicks off the one-time download/load in the
    /// background and returns nil immediately, so the caller falls back to the
    /// deterministic ordering for this rank and picks the model up on a later
    /// one. Ranks are awaited from `refresh()` behind the app-wide loading
    /// screen; blocking that on a first-use ~1GB Hugging Face download (no
    /// timeout, no progress) hung the whole app.
    func container() async -> ModelContainer? {
        let requestedID = MLXRanker.modelID
        if let loadedContainer, loadedHubID == requestedID { return loadedContainer }
        // One load at a time; if the user switched models while a load is in
        // flight, the mismatch is noticed on the next rank once it finishes.
        if loadTask == nil {
            loadTask = Task<ModelContainer?, Never> {
                do {
                    // Give MLX a modest GPU cache budget; harmless if unsupported.
                    MLX.GPU.set(cacheLimit: 256 * 1024 * 1024)
                    let container = try await loadModelContainer(id: requestedID)
                    await self.finishLoad(container, hubID: requestedID)
                    return container
                } catch {
                    self.recordLoadFailure(error)
                    await self.finishLoad(nil, hubID: requestedID)
                    return nil
                }
            }
        }
        return nil
    }

    private func finishLoad(_ container: ModelContainer?, hubID: String) {
        if let container {
            // Replaces any previously loaded model (ARC frees the old one).
            loadedContainer = container
            loadedHubID = hubID
            lastUnavailableMessage = nil
        }
        loadTask = nil
    }

    private func recordLoadFailure(_ error: Error) {
        // The most common first-run failure is no network for the model
        // download. Keep the message actionable but generic.
        lastUnavailableMessage =
            "Couldn't load the MLX model (\(MLXRanker.modelID)). It downloads on first use — check the network and free memory. Using basic sorting for now."
    }
}
#endif
