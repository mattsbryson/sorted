import Foundation

/// Deterministic fallback/pre-sort used when Apple Intelligence is unavailable,
/// and to pick which reminders get sent to the model when the list is large.
enum HeuristicRanker {
    static func sort(_ items: [ReminderItem]) -> [ReminderItem] {
        let now = Date()
        func score(_ item: ReminderItem) -> Double {
            var s = 0.0
            if item.isFlagged { s += 50 }
            switch item.priorityLevel {
            case .high: s += 30
            case .medium: s += 15
            case .low: s += 5
            case .none: s += 0
            }
            if let due = item.dueDate {
                let hours = due.timeIntervalSince(now) / 3600
                if hours < 0 {
                    s += 100 + min(-hours, 5000) / 10
                } else {
                    s += max(0, 100 - hours / 24)
                }
            }
            return s
        }
        return items.sorted { score($0) > score($1) }
    }
}
