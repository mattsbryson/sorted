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

    /// `ImportanceCache` namespace for this model's judgments — one model's
    /// tiers must never be served as another's, and switching models in
    /// Settings shouldn't discard a different model's warm cache.
    var cacheNamespace: String { "mlx.\(rawValue)" }

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

/// Option 2 of the ranking A/B: an on-device open LLM run via MLX Swift,
/// used with **exactly `AIPrioritizer`'s two-axis architecture** — per-item
/// importance classification (date-blind, cached per model) + deterministic
/// time urgency (`UrgencyScorer`) + one listwise re-rank of the top slice.
///
/// This arm originally ranked with a single large comparative pass (~40
/// reminders judged together). A/B testing showed Apple's per-item structure
/// beating pure listwise across every MLX model, so the arm now varies only
/// the *model*, not the design: the interesting question left is whether a
/// bigger open model classifies importance better than Apple's ~3B.
///
/// Prompt conventions mirror the baseline: reminders are labelled with short
/// tokens `R0..Rn`, due/creation dates are **pre-computed in Swift** to
/// relative offsets (small models are unreliable at date math, so we never
/// ask the model to do it), and free-text replies are parsed defensively —
/// anything omitted keeps its fallback/deterministic position.
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
    /// Classification chunk size: how many reminders go into one per-item
    /// importance prompt. Larger than the Apple arm's 15 because the open
    /// models aren't bound by the ~4096-token FoundationModels context.
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

    /// How many of the top-ranked reminders get the listwise re-rank pass —
    /// same slice as `AIPrioritizer.reorderCount`.
    static let reorderCount = 15

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

    /// Ranks all items most- to least-important, mirroring `AIPrioritizer`'s
    /// two-axis architecture — which won the A/B against this arm's original
    /// single listwise big-batch pass (Apple's structure beat pure listwise
    /// even with bigger models, so the MLX arm now varies only the model,
    /// not the design):
    ///
    /// - **Importance**: the MLX model classifies each reminder into an
    ///   `ImportanceTier` from content alone — batched prompts, date-blind —
    ///   cached per reminder *per model* (`ImportanceCache` namespace) until
    ///   its content changes.
    /// - **Time urgency**: `UrgencyScorer` computes it deterministically from
    ///   the dates at rank time and combines the axes.
    /// - **Top re-rank**: one listwise pass over the top `reorderCount`
    ///   candidates restores comparative fine ordering, exactly like
    ///   `AIPrioritizer.reorderTop`.
    ///
    /// Falls back to the priority-flag heuristic ordering whenever the model
    /// isn't ready (still downloading) or a call fails/omits items.
    func rank(_ items: [ReminderItem], consideringDueDates: Bool = true) async -> [ReminderItem] {
        guard !items.isEmpty else { return [] }
        let now = Date()

        #if canImport(MLXLLM) && canImport(MLXLMCommon) && arch(arm64) && !SORTED_TESTS
        guard let container = await ModelStore.shared.container() else {
            return Self.deterministicOrder(items, consideringDueDates: consideringDueDates, now: now)
        }

        let choice = MLXModelChoice.current
        // MLX-classified importance only; fallback tiers are applied at
        // scoring time below and never cached, so they can't be served as if
        // the model had judged them (same rule as AIPrioritizer).
        var tiers = ImportanceCache.cachedTiers(for: items, namespace: choice.cacheNamespace)
        let toClassify = items.filter { tiers[$0.id] == nil }
        if !toClassify.isEmpty {
            let classified = await Self.batchClassify(toClassify, container: container, choice: choice)
            tiers.merge(classified) { _, new in new }
        }
        ImportanceCache.save(items: items, tiers: tiers, namespace: choice.cacheNamespace)

        let scored = items.map { item in
            let tier = tiers[item.id] ?? UrgencyScorer.fallbackImportance(for: item)
            return item.withScore(UrgencyScorer.score(
                importance: tier,
                item: item,
                now: now,
                consideringDueDates: consideringDueDates
            ))
        }
        let ranked = Self.sortByScore(scored, originalOrder: items)
        return await Self.reorderTop(
            ranked, container: container, includeDates: consideringDueDates, now: now)
        #else
        return Self.deterministicOrder(items, consideringDueDates: consideringDueDates, now: now)
        #endif
    }
    #endif

    // MARK: - Deterministic ordering & fallback

    /// The `UrgencyScorer`-based ordering used as the fallback whenever the
    /// model can't run. No AI importance is available here, so importance is
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
        return sortByScore(scored, originalOrder: items)
    }

    /// Highest score first; ties break by earlier due date (undated last),
    /// then stable original order — identical to `AIPrioritizer.sortRanked`.
    static func sortByScore(_ scored: [ReminderItem], originalOrder: [ReminderItem]) -> [ReminderItem] {
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

    /// Builds the per-item importance-classification prompt for a batch —
    /// the MLX counterpart of `AIPrioritizer.classifyWithModel`'s prompt.
    /// Content only (title, notes, list), deliberately date-blind: the model
    /// judges consequence, never deadline pressure. Pure, so it's testable
    /// without the model.
    static func buildClassificationPrompt(
        for batch: [ReminderItem]
    ) -> (instructions: String, prompt: String, tokenToID: [String: String]) {
        var tokenToID: [String: String] = [:]
        let lines = batch.enumerated().map { index, item -> String in
            let token = "R\(index)"
            tokenToID[token] = item.id
            return formatLine(token: token, item: item)
        }

        let instructions = """
        You judge the real-world importance of a person's reminders \
        (to-dos): how much it matters that each task ever gets done, based \
        only on what the task is — its title, notes, and which list it's in. \
        Ignore timing entirely: due dates and scheduling are handled \
        separately by the app, so importance here means consequence, not \
        deadline pressure. A trivial errand is still low importance even if \
        marked urgent, and a serious obligation is still critical even with \
        no deadline mentioned. Respond with one line per reminder in the \
        form TOKEN=TIER, where TIER is one of critical, high, normal, low — \
        for example "R0=high" — and nothing else: no commentary, numbering, \
        or punctuation.
        """

        let prompt = "Classify these reminders' importance:\n" + lines.joined(separator: "\n")
        return (instructions, prompt, tokenToID)
    }

    /// Parses classification output back into id -> tier. Open models emit
    /// free text, so scan for `R<n>` followed by a tier word separated only
    /// by whitespace or =/:/- punctuation; unknown tokens are dropped and
    /// the first judgment per token wins. Pure and unit-tested.
    static func parseTiers(_ output: String, tokenToID: [String: String]) -> [String: ImportanceTier] {
        let scanner = output as NSString
        let pattern = "(R[0-9]+)[\\s=:>-]+(critical|high|normal|low)"
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            return [:]
        }
        var result: [String: ImportanceTier] = [:]
        let matches = regex.matches(in: output, range: NSRange(location: 0, length: scanner.length))
        for match in matches {
            let token = scanner.substring(with: match.range(at: 1))
            let tierRaw = scanner.substring(with: match.range(at: 2)).lowercased()
            guard let id = tokenToID[token], result[id] == nil,
                  let tier = ImportanceTier(rawValue: tierRaw) else { continue }
            result[id] = tier
        }
        return result
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
    /// Splits items into model-sized chunks and classifies each into an
    /// importance tier — the MLX counterpart of `AIPrioritizer.batchClassify`.
    /// A fresh `ChatSession` per chunk keeps judgments independent. Items the
    /// model omits (or a failed chunk) yield no entry, leaving the caller's
    /// priority-flag fallback to cover them for this rank only.
    static func batchClassify(
        _ items: [ReminderItem],
        container: ModelContainer,
        choice: MLXModelChoice
    ) async -> [String: ImportanceTier] {
        guard !items.isEmpty else { return [:] }
        var result: [String: ImportanceTier] = [:]
        let batchSize = Self.batchSize(for: choice)
        for start in stride(from: 0, to: items.count, by: batchSize) {
            let chunk = Array(items[start..<min(start + batchSize, items.count)])
            let (instructions, prompt, tokenToID) = buildClassificationPrompt(for: chunk)
            do {
                let session = ChatSession(
                    container,
                    instructions: instructions,
                    generateParameters: GenerateParameters(maxTokens: maxTokens, temperature: 0))
                let output = try await session.respond(to: prompt)
                let tiers = parseTiers(output, tokenToID: tokenToID)
                #if DEBUG
                print("MLXRanker[\(choice.rawValue)]: classified \(tiers.count)/\(chunk.count) of chunk")
                #endif
                result.merge(tiers) { _, new in new }
            } catch {
                #if DEBUG
                print("MLXRanker[\(choice.rawValue)]: classification failed — \(error)")
                #endif
            }
        }
        return result
    }

    /// Listwise re-rank of the top of the list, mirroring
    /// `AIPrioritizer.reorderTop`: per-item tiers pick *which* reminders
    /// matter most, then one comparative pass orders that group side by
    /// side. Not cached: `TopOrderCache` holds the Apple arm's orderings,
    /// and serving one model's judgment as another's would corrupt the A/B —
    /// one small extra call per refresh is the honest price.
    static func reorderTop(
        _ ranked: [ReminderItem],
        container: ModelContainer,
        includeDates: Bool,
        now: Date
    ) async -> [ReminderItem] {
        let count = min(reorderCount, ranked.count)
        guard count > 1 else { return ranked }
        let candidates = Array(ranked.prefix(count))

        let orderedIDs = await listwiseOrder(
            candidates, container: container, includeDates: includeDates, now: now)
        guard !orderedIDs.isEmpty else { return ranked }

        // Rebuild the slice in the model's order (omissions keep their prior
        // position) and reassign the slice's scores in the new order so
        // displayed scores stay monotonically decreasing down the list.
        let rebuilt = reorder(candidates, byIDs: orderedIDs)
        let slotScores = candidates.map { $0.score ?? 0 }
        let rescored = zip(rebuilt, slotScores).map { $0.withScore($1) }
        return rescored + ranked.dropFirst(count)
    }

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
