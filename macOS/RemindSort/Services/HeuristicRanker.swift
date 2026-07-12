import Foundation

/// Deterministic fallback used when Apple Intelligence is unavailable, and
/// as a per-item fallback when a model call fails or is skipped.
enum HeuristicRanker {
    static func score(_ item: ReminderItem, now: Date = Date()) -> Double {
        var s = 0.0
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

    static func sort(_ items: [ReminderItem]) -> [ReminderItem] {
        let now = Date()
        return items.sorted { score($0, now: now) > score($1, now: now) }
    }
}
