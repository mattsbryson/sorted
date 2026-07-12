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

    /// Returns all items ranked from most to least important, using an
    /// independent 0-100 urgency score per reminder from the on-device model
    /// where possible, falling back to a heuristic score otherwise.
    ///
    /// Only reminders whose content hash isn't already cached get a fresh
    /// score; everything else reuses its previous score for free. Because
    /// scores are absolute (not relative to a batch), combining cached and
    /// freshly-scored items is just a plain sort — no merging required.
    ///
    /// `onProgress` (if given) is called on the main actor with a 0...1
    /// fraction as batches complete; it's an estimate, capped below 1 until
    /// scoring actually finishes.
    func rank(_ items: [ReminderItem], onProgress: (@MainActor (Double) -> Void)? = nil) async -> [ReminderItem] {
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

        if !toScore.isEmpty {
            let totalBatches = max(1, Int((Double(toScore.count) / Double(Self.batchSize)).rounded(.up)))
            let tracker = ProgressTracker(estimatedCalls: totalBatches, onProgress: onProgress)
            let preSorted = HeuristicRanker.sort(toScore)

            for start in stride(from: 0, to: preSorted.count, by: Self.batchSize) {
                let chunk = Array(preSorted[start..<min(start + Self.batchSize, preSorted.count)])
                let batchScores = await scoreWithModel(chunk)
                for (id, score) in batchScores {
                    scores[id] = score
                }
                await tracker.advance()
            }
        }

        ScoreCache.save(items: items, scores: scores)
        await onProgress?(1)

        let now = Date()
        let heuristicOrder = HeuristicRanker.sort(items)
        let heuristicIndex = Dictionary(uniqueKeysWithValues: heuristicOrder.enumerated().map { ($1.id, $0) })

        return items.sorted { a, b in
            let scoreA = scores[a.id] ?? Int(HeuristicRanker.score(a, now: now))
            let scoreB = scores[b.id] ?? Int(HeuristicRanker.score(b, now: now))
            if scoreA != scoreB { return scoreA > scoreB }
            // Stable tie-break so equal scores don't jump around between runs.
            return (heuristicIndex[a.id] ?? .max) < (heuristicIndex[b.id] ?? .max)
        }
    }

    /// Scores one batch (<=batchSize) of reminders via the model. Never
    /// throws to the caller — falls back to a heuristic-derived score per
    /// item on any failure, or for anything the model's response omits.
    private func scoreWithModel(_ batch: [ReminderItem]) async -> [String: Int] {
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

        do {
            let prompt = "Score these reminders' urgency from 0-100:\n" + lines.joined(separator: "\n")
            let response = try await session.respond(to: prompt, generating: UrgencyScores.self)

            var result: [String: Int] = [:]
            for entry in response.content.scores {
                if let id = tokenToID[entry.token] {
                    result[id] = min(100, max(0, entry.score))
                }
            }
            // Fall back to a heuristic score for anything the model omitted.
            let now = Date()
            for item in batch where result[item.id] == nil {
                result[item.id] = Int(HeuristicRanker.score(item, now: now))
            }
            return result
        } catch {
            let now = Date()
            var result: [String: Int] = [:]
            for item in batch {
                result[item.id] = Int(HeuristicRanker.score(item, now: now))
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
