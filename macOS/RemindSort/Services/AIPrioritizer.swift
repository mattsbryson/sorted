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

    /// True only before the score cache has ever been populated — i.e. this
    /// would be the very first scoring pass this app has ever done.
    static func isFirstPass() -> Bool {
        !ScoreCache.hasAnyCachedScores()
    }

    /// Returns all items ranked from most to least important. `onProgress`
    /// reports an approximate 0...1 fraction while any synchronous work runs
    /// (in practice, negligible). `onImproved` (if given) is called on the
    /// main actor, potentially more than once, as background scoring passes
    /// produce better-quality scores than what was returned synchronously —
    /// the caller should treat each call as a live update, not a loading
    /// state.
    ///
    /// New or changed reminders (including on the very first pass ever, with
    /// an empty cache) get an instant heuristic placeholder score so nothing
    /// ever blocks the UI. Two background passes then refine that, in order:
    ///
    /// 1. A batched pass (<=batchSize reminders per call) gives everyone a
    ///    real AI score reasonably quickly.
    /// 2. An individual pass (one reminder per call) re-scores each one
    ///    completely on its own, with no other reminders competing for the
    ///    model's attention in the same prompt — batching reminders together
    ///    tends to compress scores toward a narrow band, since the model is
    ///    implicitly comparing them; scoring alone avoids that bias. This is
    ///    slower (one model call per reminder) but runs entirely in the
    ///    background, and every score gets cached, so it's a one-time cost
    ///    per reminder — unchanged reminders never pay it again.
    func rank(
        _ items: [ReminderItem],
        onProgress: (@MainActor (Double) -> Void)? = nil,
        onImproved: (@MainActor ([ReminderItem]) -> Void)? = nil
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
            // Everything's already cached — no model call, no background work.
            await onProgress?(1)
            return sortByScore(items, scores: scores)
        }

        let now = Date()
        for item in toScore {
            scores[item.id] = clampedScore(HeuristicRanker.score(item, now: now))
        }
        let placeholderResult = sortByScore(items, scores: scores)
        await onProgress?(1)

        Task {
            // Pass 1: batched — everyone gets a real score reasonably fast.
            let batched = await batchScore(toScore, batchSize: Self.batchSize, onProgress: nil)
            var refined = scores
            for (id, score) in batched { refined[id] = score }
            ScoreCache.save(items: items, scores: refined)
            await onImproved?(sortByScore(items, scores: refined))

            // Pass 2: individual — re-score each one alone, free of any
            // batch-composition bias, refining what pass 1 established.
            let individual = await batchScore(toScore, batchSize: 1, onProgress: nil)
            var finalScores = refined
            for (id, score) in individual { finalScores[id] = score }
            ScoreCache.save(items: items, scores: finalScores)
            await onImproved?(sortByScore(items, scores: finalScores))
        }

        return placeholderResult
    }

    private func sortByScore(_ items: [ReminderItem], scores: [String: Int]) -> [ReminderItem] {
        let now = Date()
        let heuristicOrder = HeuristicRanker.sort(items)
        let heuristicIndex = Dictionary(uniqueKeysWithValues: heuristicOrder.enumerated().map { ($1.id, $0) })

        // Attach the score that actually determined each item's position, so
        // it's available for display (e.g. a "show urgency score" setting).
        let withScores = items.map { item in
            item.withScore(scores[item.id] ?? clampedScore(HeuristicRanker.score(item, now: now)))
        }

        return withScores.sorted { a, b in
            let scoreA = a.score ?? 0
            let scoreB = b.score ?? 0
            if scoreA != scoreB { return scoreA > scoreB }
            // Stable tie-break so equal scores don't jump around between runs.
            return (heuristicIndex[a.id] ?? .max) < (heuristicIndex[b.id] ?? .max)
        }
    }

    /// Heuristic scores aren't bounded the way AI scores are (a very overdue
    /// item can score well past 100), so anything derived from the heuristic
    /// gets clamped to the same 0-100 range the model uses — otherwise a
    /// heuristic placeholder could outrank a legitimately-scored AI item.
    private func clampedScore(_ raw: Double) -> Int {
        min(100, max(0, Int(raw)))
    }

    /// Splits items into <=chunkSize chunks and scores each with the model,
    /// reporting progress across all chunks.
    private func batchScore(
        _ items: [ReminderItem],
        batchSize chunkSize: Int,
        onProgress: (@MainActor (Double) -> Void)?
    ) async -> [String: Int] {
        guard !items.isEmpty else { return [:] }
        let totalBatches = max(1, Int((Double(items.count) / Double(chunkSize)).rounded(.up)))
        let tracker = ProgressTracker(estimatedCalls: totalBatches, onProgress: onProgress)
        let preSorted = HeuristicRanker.sort(items)

        var result: [String: Int] = [:]
        for start in stride(from: 0, to: preSorted.count, by: chunkSize) {
            let chunk = Array(preSorted[start..<min(start + chunkSize, preSorted.count)])
            let batchScores = await scoreWithModel(chunk)
            for (id, score) in batchScores {
                result[id] = score
            }
            await tracker.advance()
        }
        return result
    }

    /// The model echoes back each reminder's token alongside its score, so
    /// mapping back to items is unambiguous even if the model reorders or
    /// omits entries.
    private func scoreWithModel(_ batch: [ReminderItem]) async -> [String: Int] {
        let now = Date()
        let lines = batch.enumerated().map { index, item in
            formatLine(token: "R\(index)", item: item, now: now)
        }

        let session = LanguageModelSession(
            instructions: """
            You rate a person's reminders (to-dos) on an urgency/importance scale \
            from 0 to 100, where 100 is extremely urgent or important and 0 is not \
            urgent at all. Each reminder's due date and creation date are given as \
            relative offsets from today (e.g. "due in 3 days", "overdue by 12 days", \
            "created 45 days ago") — use these directly rather than estimating dates \
            yourself. As a rough guide: a reminder overdue by more than a few days, \
            or due very soon with real stakes evident from its title or notes, \
            should score 80-100; a reminder due within the next week or two should \
            score 40-70; a reminder with no due date, created recently, should score \
            10-30, trending higher the longer it has sat untouched so it doesn't get \
            perpetually neglected. Use the title, notes, and list/project to judge \
            real-world stakes and urgency — use the full 0-100 range rather than \
            clustering everything near the same value. Respond only with the \
            requested scores.
            """
        )

        var tokenToID: [String: String] = [:]
        for (index, item) in batch.enumerated() {
            tokenToID["R\(index)"] = item.id
        }

        do {
            let prompt = "Score these reminders' urgency from 0-100:\n" + lines.joined(separator: "\n")
            let response = try await session.respond(to: prompt, generating: UrgencyScores.self)

            var result: [String: Int] = [:]
            for entry in response.content.scores {
                if let id = tokenToID[entry.token] {
                    result[id] = min(100, max(0, entry.score))
                }
            }
            for item in batch where result[item.id] == nil {
                result[item.id] = clampedScore(HeuristicRanker.score(item, now: now))
            }
            return result
        } catch {
            var result: [String: Int] = [:]
            for item in batch {
                result[item.id] = clampedScore(HeuristicRanker.score(item, now: now))
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
