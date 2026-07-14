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

    /// Small quantized instruct model pulled from the Hugging Face hub on first
    /// use. ~1.5B params at 4-bit is a few hundred MB and runs comfortably on
    /// modern Apple-Silicon phones/Macs while giving far more headroom than the
    /// baseline. Swappable for `mlx-community/Llama-3.2-1B-Instruct-4bit` if a
    /// smaller footprint is wanted.
    static let modelID = "mlx-community/Qwen2.5-1.5B-Instruct-4bit"

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
        if ModelStore.shared.isLoaded {
            return .available
        }
        // Not yet loaded: the model downloads/loads lazily on first rank. We
        // report available (it *can* run) but note the one-time fetch so the UI
        // can explain the initial delay.
        return .available
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
        for start in stride(from: 0, to: preSorted.count, by: Self.batchSize) {
            let chunk = Array(preSorted[start..<min(start + Self.batchSize, preSorted.count)])
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
            return parseOrder(output, tokenToID: tokenToID)
        } catch {
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

    /// Best-effort flag for availability reporting from a synchronous context.
    /// nonisolated(unsafe) is acceptable: it's a plain read for a UI hint, and a
    /// stale value only affects an advisory message, never correctness.
    nonisolated(unsafe) private(set) var isLoaded = false
    nonisolated(unsafe) private(set) var lastUnavailableMessage: String?

    /// Returns the loaded container, kicking off (and de-duping) the one-time
    /// load on first call. Returns nil if the model can't be loaded (no
    /// network for the initial download, out of memory, unsupported), letting
    /// the ranker fall back to deterministic ordering.
    func container() async -> ModelContainer? {
        if let loadedContainer { return loadedContainer }
        if let loadTask { return await loadTask.value }

        let task = Task<ModelContainer?, Never> { [modelID = MLXRanker.modelID] in
            do {
                // Give MLX a modest GPU cache budget; harmless if unsupported.
                MLX.GPU.set(cacheLimit: 256 * 1024 * 1024)
                let container = try await loadModelContainer(id: modelID)
                return container
            } catch {
                self.recordLoadFailure(error)
                return nil
            }
        }
        loadTask = task
        let result = await task.value
        if let result {
            loadedContainer = result
            isLoaded = true
            lastUnavailableMessage = nil
        }
        loadTask = nil
        return result
    }

    private func recordLoadFailure(_ error: Error) {
        // The most common first-run failure is no network for the model
        // download. Keep the message actionable but generic.
        lastUnavailableMessage =
            "Couldn't load the MLX model (\(MLXRanker.modelID)). It downloads on first use — check the network and free memory. Using basic sorting for now."
    }
}
#endif
