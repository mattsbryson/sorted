import Foundation

enum ReminderPriorityLevel: String, Sendable {
    case high, medium, low, none

    /// Maps EventKit's raw priority (0 = none, 1-4 = high, 5 = medium, 6-9 = low per RFC 5545).
    init(rawPriority: Int) {
        switch rawPriority {
        case 1...4: self = .high
        case 5: self = .medium
        case 6...9: self = .low
        default: self = .none
        }
    }
}

struct ReminderItem: Identifiable, Hashable, Sendable {
    let id: String
    let title: String
    let notes: String?
    let dueDate: Date?
    let rawPriority: Int
    let listName: String

    var priorityLevel: ReminderPriorityLevel { ReminderPriorityLevel(rawPriority: rawPriority) }

    var isOverdue: Bool {
        guard let dueDate else { return false }
        return dueDate < Date() && !Calendar.current.isDateInToday(dueDate)
    }
}
