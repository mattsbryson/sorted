import Foundation
import FoundationModels

enum AIAvailability: Sendable {
    case available
    case unavailable(String)
}

struct AIPrioritizer {
    /// The model's context window limits how many reminders can be judged in
    /// a single call. Kept small (well under the 4096-token ceiling) so each
    /// reminder gets more careful individual attention rather than being
    /// diluted across a large batch.
    private static let batchSize = 15

    /// Score range assigned to each tier; reminders within a tier are spread
    /// evenly across its band in stable original order — the AI's tier
    /// classification is the only priority signal, not a heuristic.
    private static let tierBands: [UrgencyTier: ClosedRange<Int>] = [
        .critical: 90...100,
        .high: 70...89,
        .medium: 45...69,
        .low: 20...44,
        .minimal: 0...19,
    ]

    static var availability: AIAvailability {
        switch SystemLanguageModel.default.availability {
        case .available:
            return .available
        case .unavailable(.deviceNotEligible):
            return .unavailable("This Mac doesn't support Apple Intelligence.")
        case .unavailable(.appleIntelligenceNotEnabled):
            return .unavailable("Turn on Apple Intelligence in System Settings to enable AI sorting.")
        case .unavailable(.modelNotReady):
            return .unavailable("Apple Intelligence model is still downloading. Using basic sorting for now.")
        case .unavailable:
            return .unavailable("Apple Intelligence is unavailable. Using basic sorting for now.")
        }
    }

    /// Returns all items ranked from most to least important. `onProgress`
    /// reports an approximate 0...1 fraction while the model classifies
    /// new/changed reminders — callers should show a loading state for the
    /// duration of this call, since (unlike an earlier version) nothing
    /// happens in the background afterward.
    ///
    /// Each new/changed reminder is classified by the model into a coarse
    /// urgency tier (critical/high/medium/low/minimal) rather than asked for
    /// a fine-grained number directly — categorical judgments are a more
    /// reliable task for the on-device model. The final 0-100 score is then
    /// computed in code: reminders sharing a tier are spread evenly across
    /// that tier's band in the order the model returned them — priority is
    /// AI-only, so there's no heuristic re-sorting mixed in once the model
    /// has actually classified an item. The heuristic (`HeuristicRanker`) is
    /// kept only as a fallback for when the model can't produce a real
    /// answer at all (Apple Intelligence unavailable, a model call throwing,
    /// or a specific reminder missing from the model's response). Already-
    /// cached reminders are free; if nothing needs classifying, this returns
    /// immediately with no model call at all.
    func rank(
        _ items: [ReminderItem],
        onProgress: (@MainActor (Double) -> Void)? = nil
    ) async -> [ReminderItem] {
        guard !items.isEmpty else {
            await onProgress?(1)
            return []
        }

        guard case .available = Self.availability else {
            let sorted = HeuristicRanker.sort(items)
            await onProgress?(1)
            return sorted
        }

        var scores = ScoreCache.cachedScores(for: items)
        let toScore = items.filter { scores[$0.id] == nil }

        guard !toScore.isEmpty else {
            // Everything's already cached — no model call.
            await onProgress?(1)
            return sortByScore(items, scores: scores)
        }

        let now = Date()
        let tiers = await batchClassify(toScore, onProgress: onProgress)
        for (id, score) in computeScores(for: toScore, tiers: tiers, now: now) {
            scores[id] = score
        }

        ScoreCache.save(items: items, scores: scores)
        await onProgress?(1)
        return sortByScore(items, scores: scores)
    }

    /// Converts tier classifications into concrete 0-100 scores: reminders
    /// in the same tier are spread evenly across that tier's band in stable
    /// original order (no heuristic re-sorting — the AI's tier is the only
    /// priority signal once it's actually classified something). Anything
    /// the model didn't classify falls back to a heuristic-derived tier,
    /// since that's a real failure case, not a normal AI-classified item.
    private func computeScores(
        for items: [ReminderItem],
        tiers: [String: UrgencyTier],
        now: Date
    ) -> [String: Int] {
        var byTier: [UrgencyTier: [ReminderItem]] = [:]
        for item in items {
            let tier = tiers[item.id] ?? heuristicTier(for: item, now: now)
            byTier[tier, default: []].append(item)
        }

        var scores: [String: Int] = [:]
        for tier in UrgencyTier.allCases {
            guard let group = byTier[tier], !group.isEmpty else { continue }
            guard let band = Self.tierBands[tier] else { continue }

            if group.count == 1 {
                scores[group[0].id] = band.upperBound
                continue
            }
            let span = Double(band.upperBound - band.lowerBound)
            for (index, item) in group.enumerated() {
                // 1.0 for the first in the group, 0.0 for the last — stable
                // original order, not a heuristic-derived ranking.
                let fraction = Double(group.count - 1 - index) / Double(group.count - 1)
                scores[item.id] = Int((Double(band.lowerBound) + fraction * span).rounded())
            }
        }
        return scores
    }

    /// Coarse fallback tier derived purely from the heuristic, used only
    /// when the model omits a reminder from its response.
    private func heuristicTier(for item: ReminderItem, now: Date) -> UrgencyTier {
        switch HeuristicRanker.score(item, now: now) {
        case 95...: .critical
        case 55..<95: .high
        case 18..<55: .medium
        case 5..<18: .low
        default: .minimal
        }
    }

    /// Used only if an item somehow has no score at all (shouldn't happen —
    /// every classified item gets one via `computeScores`, and every cached
    /// item has one by construction). A fixed neutral value rather than a
    /// heuristic score, so priority stays AI-only even in this dead-code
    /// path.
    private static let fallbackScore = 50

    private func sortByScore(_ items: [ReminderItem], scores: [String: Int]) -> [ReminderItem] {
        let originalIndex = Dictionary(uniqueKeysWithValues: items.enumerated().map { ($1.id, $0) })

        // Attach the score that actually determined each item's position, so
        // it's available for display (e.g. a "show urgency score" setting).
        let withScores = items.map { item in
            item.withScore(scores[item.id] ?? Self.fallbackScore)
        }

        return withScores.sorted { a, b in
            let scoreA = a.score ?? 0
            let scoreB = b.score ?? 0
            if scoreA != scoreB { return scoreA > scoreB }
            // Stable tie-break in original fetch order — not a heuristic
            // re-sort — so equal scores don't jump around between runs.
            return (originalIndex[a.id] ?? .max) < (originalIndex[b.id] ?? .max)
        }
    }

    /// Splits items into <=batchSize chunks and classifies each with the
    /// model, reporting progress across all chunks.
    private func batchClassify(
        _ items: [ReminderItem],
        onProgress: (@MainActor (Double) -> Void)?
    ) async -> [String: UrgencyTier] {
        guard !items.isEmpty else { return [:] }
        let totalBatches = max(1, Int((Double(items.count) / Double(Self.batchSize)).rounded(.up)))
        let tracker = ProgressTracker(estimatedCalls: totalBatches, onProgress: onProgress)

        // Chunked in original order, not heuristic-sorted — batch
        // composition shouldn't be influenced by the heuristic either, since
        // each reminder is judged independently regardless of chunk order.
        var result: [String: UrgencyTier] = [:]
        for start in stride(from: 0, to: items.count, by: Self.batchSize) {
            let chunk = Array(items[start..<min(start + Self.batchSize, items.count)])
            let batchTiers = await classifyWithModel(chunk)
            for (id, tier) in batchTiers {
                result[id] = tier
            }
            await tracker.advance()
        }
        return result
    }

    /// The model echoes back each reminder's token alongside its tier, so
    /// mapping back to items is unambiguous even if the model reorders or
    /// omits entries.
    private func classifyWithModel(_ batch: [ReminderItem]) async -> [String: UrgencyTier] {
        let now = Date()
        let lines = batch.enumerated().map { index, item in
            formatLine(token: "R\(index)", item: item, now: now)
        }

        let session = LanguageModelSession(
            instructions: """
            You classify a person's reminders (to-dos) into urgency tiers: \
            critical, high, medium, low, or minimal. Each reminder's due date \
            and creation date are given as relative offsets from today (e.g. \
            "due in 3 days", "overdue by 12 days", "created 45 days ago") — use \
            these directly rather than estimating dates yourself. Use the title, \
            notes, and list/project to judge real-world stakes too. Respond only \
            with the requested tier classifications.
            """
        )

        var tokenToID: [String: String] = [:]
        for (index, item) in batch.enumerated() {
            tokenToID["R\(index)"] = item.id
        }

        do {
            let prompt = "Classify these reminders' urgency:\n" + lines.joined(separator: "\n")
            let response = try await session.respond(to: prompt, generating: UrgencyTiers.self)

            var result: [String: UrgencyTier] = [:]
            for entry in response.content.tiers {
                if let id = tokenToID[entry.token] {
                    result[id] = entry.tier
                }
            }
            for item in batch where result[item.id] == nil {
                result[item.id] = heuristicTier(for: item, now: now)
            }
            return result
        } catch {
            var result: [String: UrgencyTier] = [:]
            for item in batch {
                result[item.id] = heuristicTier(for: item, now: now)
            }
            return result
        }
    }

    private func formatLine(token: String, item: ReminderItem, now: Date) -> String {
        var parts = ["[\(token)]", "title=\"\(item.title)\"", "list=\"\(item.listName)\""]

        parts.append("due=\(relativeDayDescription(for: item.dueDate, now: now, pastPrefix: "overdue by", pastSuffix: "", futurePrefix: "in", noneValue: "none"))")

        if let created = item.creationDate {
            parts.append("created=\(relativeDayDescription(for: created, now: now, pastPrefix: "", pastSuffix: "ago", futurePrefix: "in", noneValue: "unknown"))")
        }

        if let notes = item.notes, !notes.isEmpty {
            let trimmed = notes.count > 140 ? String(notes.prefix(140)) + "…" : notes
            parts.append("notes=\"\(trimmed)\"")
        }

        return parts.joined(separator: " ")
    }

    /// Converts an absolute date into a human-readable relative description
    /// ("overdue by 12 days", "in 3 days", "45 days ago", "today") anchored
    /// to `now`, computed by the app rather than left for the model to infer
    /// from two raw timestamps — on-device models are unreliable at date
    /// arithmetic, so doing it here removes that entire failure mode.
    private func relativeDayDescription(
        for date: Date?,
        now: Date,
        pastPrefix: String,
        pastSuffix: String,
        futurePrefix: String,
        noneValue: String
    ) -> String {
        guard let date else { return noneValue }
        // Calendar-day difference (midnight to midnight), not a raw 24h
        // rounding — otherwise something due at 11pm today, checked at 9am,
        // would misleadingly read as "in 1 day" instead of "today".
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

/// Tracks completed-vs-estimated model calls for one scoring pass and reports
/// an approximate 0...1 fraction, capped below 1 until the caller marks
/// completion explicitly.
private final class ProgressTracker {
    private let total: Int
    private var completed = 0
    private let onProgress: (@MainActor (Double) -> Void)?

    init(estimatedCalls: Int, onProgress: (@MainActor (Double) -> Void)?) {
        self.total = max(estimatedCalls, 1)
        self.onProgress = onProgress
    }

    func advance() async {
        completed += 1
        let fraction = min(0.95, Double(completed) / Double(total))
        await onProgress?(fraction)
    }
}
