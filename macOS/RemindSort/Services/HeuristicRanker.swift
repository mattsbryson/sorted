import Foundation

/// Deterministic fallback used when Apple Intelligence is unavailable, and
/// as a per-item fallback when a model call fails or is skipped.
enum HeuristicRanker {
    static func score(_ item: ReminderItem, now: Date = Date()) -> Double {
        var s = 0.0
        switch item.priorityLevel {
        case .high: s += 40
        case .medium: s += 20
        case .low: s += 8
        case .none: s += 0
        }
        if let due = item.dueDate {
            let hours = due.timeIntervalSince(now) / 3600
            if hours < 0 {
                // Being overdue at all is the strong signal; how much *more*
                // overdue matters far less, and is capped (10 days) so a
                // long-overdue, low-priority reminder can't drown out the
                // priority term the way an uncapped bonus did.
                s += 60 + min(-hours, 240) / 12
            } else {
                // Fades out over ~15 days so far-future due dates barely
                // register, without an unbounded penalty in the other
                // direction.
                s += max(0, 60 - hours / 6)
            }
        }
        return s
    }

    static func sort(_ items: [ReminderItem]) -> [ReminderItem] {
        let now = Date()
        return items.sorted { score($0, now: now) > score($1, now: now) }
    }
}
