import Foundation
import FoundationModels

enum AIAvailability: Sendable {
    case available
    case unavailable(String)
}

struct AIPrioritizer {
    /// The model's context window limits how many reminders can be judged in
    /// a single call, so ranking is split into batches of at most this size.
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

    /// Returns all items ranked from most to least important, using the on-device
    /// model where possible and falling back to heuristics otherwise. Skips the
    /// (slow) model call entirely if nothing has changed since the last ranking.
    func rank(_ items: [ReminderItem]) async -> [ReminderItem] {
        guard !items.isEmpty else { return [] }

        let fingerprint = RankingCache.fingerprint(for: items)
        if let cachedOrder = RankingCache.loadOrder(matching: fingerprint) {
            let byID = Dictionary(uniqueKeysWithValues: items.map { ($0.id, $0) })
            let cached = cachedOrder.compactMap { byID[$0] }
            if cached.count == items.count {
                return cached
            }
        }

        guard case .available = Self.availability else {
            return HeuristicRanker.sort(items)
        }

        let result = await rankAll(items)
        RankingCache.save(fingerprint: fingerprint, order: result.map(\.id))
        return result
    }

    /// Splits the full set into <=batchSize chunks, ranks each chunk
    /// independently, then merges the ranked chunks together.
    private func rankAll(_ items: [ReminderItem]) async -> [ReminderItem] {
        let preSorted = HeuristicRanker.sort(items)

        guard preSorted.count > Self.batchSize else {
            return (try? await rankWithModel(preSorted)) ?? preSorted
        }

        var runs: [[ReminderItem]] = []
        for start in stride(from: 0, to: preSorted.count, by: Self.batchSize) {
            let chunk = Array(preSorted[start..<min(start + Self.batchSize, preSorted.count)])
            let ranked = (try? await rankWithModel(chunk)) ?? chunk
            runs.append(ranked)
        }

        return await mergeRuns(runs)
    }

    /// A k-way "merge sort" merge, generalized from pairwise comparison to
    /// batch comparison: each round takes the top N items off every remaining
    /// run (N chosen so the combined pool stays within batchSize), asks the
    /// model to rank that pool together, locks the result into the final
    /// order, and continues with the shortened runs until everything merges.
    private func mergeRuns(_ initialRuns: [[ReminderItem]]) async -> [ReminderItem] {
        var runs = initialRuns.filter { !$0.isEmpty }
        var result: [ReminderItem] = []

        while runs.count > 1 {
            let perRun = max(1, Self.batchSize / runs.count)
            var pool: [ReminderItem] = []
            var taken: [Int] = []
            for run in runs {
                let take = min(perRun, run.count)
                pool.append(contentsOf: run.prefix(take))
                taken.append(take)
            }

            let ranked = (try? await rankWithModel(pool)) ?? pool
            result.append(contentsOf: ranked)

            runs = zip(runs, taken).compactMap { run, take in
                let remaining = Array(run.dropFirst(take))
                return remaining.isEmpty ? nil : remaining
            }
        }

        if let last = runs.first {
            result.append(contentsOf: last)
        }

        return result
    }

    private func rankWithModel(_ batch: [ReminderItem]) async throws -> [ReminderItem] {
        let lines = batch.enumerated().map { index, item in
            formatLine(token: "R\(index)", item: item)
        }

        let session = LanguageModelSession(
            instructions: """
            You rank a person's reminders (to-dos) by true importance and urgency. \
            Weigh due date (overdue and soon-due items are usually more urgent), \
            its explicit priority level if set, and which list/project it belongs to. \
            Use the title and notes to judge real-world stakes and urgency too. \
            Respond only with the requested ranking, nothing else.
            """
        )

        let prompt = "Rank these reminders from most to least important:\n" + lines.joined(separator: "\n")
        let response = try await session.respond(to: prompt, generating: PriorityRanking.self)

        var tokenToItem: [String: ReminderItem] = [:]
        for (index, item) in batch.enumerated() {
            tokenToItem["R\(index)"] = item
        }

        var seen = Set<String>()
        var ranked: [ReminderItem] = []
        for token in response.content.orderedTokens {
            if let item = tokenToItem[token], seen.insert(token).inserted {
                ranked.append(item)
            }
        }
        // Append anything the model omitted, preserving heuristic order.
        for (index, item) in batch.enumerated() where !seen.contains("R\(index)") {
            ranked.append(item)
        }
        return ranked
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
