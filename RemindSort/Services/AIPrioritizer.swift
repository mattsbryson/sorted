import Foundation
import FoundationModels

enum AIAvailability: Sendable {
    case available
    case unavailable(String)
}

struct AIPrioritizer {
    /// Reminders beyond this count fall back to heuristic ordering, both to keep
    /// prompts inside the on-device model's context window and keep ranking fast.
    private static let maxRankedByModel = 40

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
    /// model where possible and falling back to heuristics otherwise.
    func rank(_ items: [ReminderItem]) async -> [ReminderItem] {
        let preSorted = HeuristicRanker.sort(items)
        guard case .available = Self.availability else { return preSorted }

        let batch = Array(preSorted.prefix(Self.maxRankedByModel))
        let remainder = Array(preSorted.dropFirst(Self.maxRankedByModel))
        guard !batch.isEmpty else { return remainder }

        do {
            let ranked = try await rankWithModel(batch)
            return ranked + remainder
        } catch {
            return preSorted
        }
    }

    private func rankWithModel(_ batch: [ReminderItem]) async throws -> [ReminderItem] {
        let lines = batch.enumerated().map { index, item in
            formatLine(token: "R\(index)", item: item)
        }

        let session = LanguageModelSession(
            instructions: """
            You rank a person's reminders (to-dos) by true importance and urgency. \
            Weigh due date (overdue and soon-due items are usually more urgent), \
            whether the reminder is flagged (flagged means the person marked it as important), \
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

        parts.append("flagged=\(item.isFlagged)")
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
