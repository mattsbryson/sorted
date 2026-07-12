@preconcurrency import EventKit
import Foundation

enum RemindersAccessError: Error {
    case denied
}

@MainActor
final class RemindersService {
    private let store = EKEventStore()

    func requestAccess() async throws -> Bool {
        // EventKit invokes completion handlers on an arbitrary background queue.
        // Marking these @Sendable prevents Swift from treating them as implicitly
        // MainActor-isolated (which would trap at runtime when called off-main).
        try await withCheckedThrowingContinuation { continuation in
            store.requestFullAccessToReminders { @Sendable granted, error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: granted)
                }
            }
        }
    }

    func fetchIncompleteReminders() async throws -> [ReminderItem] {
        let calendars = store.calendars(for: .reminder)
        let predicate = store.predicateForIncompleteReminders(
            withDueDateStarting: nil,
            ending: nil,
            calendars: calendars
        )

        // EKReminder isn't Sendable, so it's mapped to the Sendable ReminderItem
        // struct inside the completion closure, before crossing back to this task.
        return await withCheckedContinuation { continuation in
            store.fetchReminders(matching: predicate) { @Sendable reminders in
                let items = (reminders ?? []).map { r in
                    ReminderItem(
                        id: r.calendarItemIdentifier,
                        title: r.title ?? "Untitled Reminder",
                        notes: r.notes,
                        dueDate: r.dueDateComponents?.date,
                        rawPriority: Int(r.priority),
                        listName: r.calendar?.title ?? "Reminders",
                        creationDate: r.creationDate,
                        score: nil
                    )
                }
                continuation.resume(returning: items)
            }
        }
    }

    func setCompleted(_ id: String, completed: Bool = true) throws {
        guard let reminder = store.calendarItem(withIdentifier: id) as? EKReminder else { return }
        reminder.isCompleted = completed
        try store.save(reminder, commit: true)
    }

    func delete(_ id: String) throws {
        guard let reminder = store.calendarItem(withIdentifier: id) as? EKReminder else { return }
        try store.remove(reminder, commit: true)
    }

    func setDueDate(_ id: String, to date: Date) throws {
        guard let reminder = store.calendarItem(withIdentifier: id) as? EKReminder else { return }
        reminder.dueDateComponents = Calendar.current.dateComponents(
            [.year, .month, .day, .hour, .minute, .second],
            from: date
        )
        try store.save(reminder, commit: true)
    }
}
