import Foundation
import FoundationModels

enum AIAvailability: Sendable {
    case available
    case unavailable(String)
}

struct AIPrioritizer {
    /// The model's context window limits how many reminders can be judged in
    /// a single call, so scoring is split into batches of at most this size.
    private static let batchSize = 40

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
    /// (in practice, negligible — see below). `onImproved` (if given) is
    /// called later, on the main actor, once a background scoring pass
    /// produces real AI-derived scores for anything that only had a
    /// heuristic placeholder — the caller should treat that as a live
    /// update, not a loading state.
    ///
    /// New or changed reminders (including on the very first pass ever, with
    /// an empty cache) get an instant heuristic placeholder score so nothing
    /// ever blocks the UI; the real model score for those reminders arrives
    /// via `onImproved` shortly after, from a background task. An earlier
    /// version tried a cheaper "quick" AI pass first instead of the
    /// heuristic placeholder, but the model doesn't reliably return the
    /// right number of scores without a per-item token to anchor each value
    /// to a specific reminder, making it worse than just using the
    /// heuristic directly.
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
            let thorough = await batchScore(toScore, using: thoroughScoreWithModel, onProgress: nil)
            var refined = scores
            for (id, score) in thorough { refined[id] = score }
            ScoreCache.save(items: items, scores: refined)
            await onImproved?(sortByScore(items, scores: refined))
        }

        return placeholderResult
    }

    private func sortByScore(_ items: [ReminderItem], scores: [String: Int]) -> [ReminderItem] {
        let now = Date()
        let heuristicOrder = HeuristicRanker.sort(items)
        let heuristicIndex = Dictionary(uniqueKeysWithValues: heuristicOrder.enumerated().map { ($1.id, $0) })

        return items.sorted { a, b in
            let scoreA = scores[a.id] ?? clampedScore(HeuristicRanker.score(a, now: now))
            let scoreB = scores[b.id] ?? clampedScore(HeuristicRanker.score(b, now: now))
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

    /// Splits items into <=batchSize chunks and scores each with the given
    /// per-batch scoring function, reporting progress across all chunks.
    private func batchScore(
        _ items: [ReminderItem],
        using scorer: ([ReminderItem]) async -> [String: Int],
        onProgress: (@MainActor (Double) -> Void)?
    ) async -> [String: Int] {
        guard !items.isEmpty else { return [:] }
        let totalBatches = max(1, Int((Double(items.count) / Double(Self.batchSize)).rounded(.up)))
        let tracker = ProgressTracker(estimatedCalls: totalBatches, onProgress: onProgress)
        let preSorted = HeuristicRanker.sort(items)

        var result: [String: Int] = [:]
        for start in stride(from: 0, to: preSorted.count, by: Self.batchSize) {
            let chunk = Array(preSorted[start..<min(start + Self.batchSize, preSorted.count)])
            let batchScores = await scorer(chunk)
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
    private func thoroughScoreWithModel(_ batch: [ReminderItem]) async -> [String: Int] {
        let lines = batch.enumerated().map { index, item in
            formatLine(token: "R\(index)", item: item)
        }

        let session = LanguageModelSession(
            instructions: """
            You rate a person's reminders (to-dos) on an urgency/importance scale \
            from 0 to 100, where 100 is extremely urgent or important and 0 is not \
            urgent at all. Weigh due date (overdue and soon-due items are usually \
            more urgent), the reminder's explicit priority level if set, and which \
            list/project it belongs to. Use the title and notes to judge real-world \
            stakes and urgency too. Give each reminder its own independent score \
            reflecting its true urgency, not just a relative rank — multiple \
            reminders can and should share similar scores if they're similarly \
            urgent. Respond only with the requested scores.
            """
        )

        var tokenToID: [String: String] = [:]
        for (index, item) in batch.enumerated() {
            tokenToID["R\(index)"] = item.id
        }

        let now = Date()
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

    private func formatLine(token: String, item: ReminderItem) -> String {
        var parts = ["[\(token)]", "title=\"\(item.title)\"", "list=\"\(item.listName)\""]

        if let due = item.dueDate {
            parts.append("due=\(Self.dateFormatter.string(from: due))")
            parts.append("overdue=\(item.isOverdue)")
        } else {
            parts.append("due=none")
        }

        parts.append("priority=\(item.priorityLevel.rawValue)")

        if let notes = item.notes, !notes.isEmpty {
            let trimmed = notes.count > 140 ? String(notes.prefix(140)) + "…" : notes
            parts.append("notes=\"\(trimmed)\"")
        }

        return parts.joined(separator: " ")
    }

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return formatter
    }()
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
