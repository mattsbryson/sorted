import Foundation
import Observation

enum LoadState: Equatable {
    case idle
    case needsAccess
    case accessDenied
    case loading
    case loaded
    case error(String)
}

@MainActor
@Observable
final class RemindersViewModel {
    private(set) var loadState: LoadState = .idle
    private(set) var rankedReminders: [ReminderItem] = []
    private(set) var homeIndex: Int = 0
    private(set) var aiNote: String?

    private let remindersService = RemindersService()
    private let prioritizer = AIPrioritizer()

    var homeReminder: ReminderItem? {
        guard !rankedReminders.isEmpty, homeIndex < rankedReminders.count else { return nil }
        return rankedReminders[homeIndex]
    }

    private static let todayLimit = 5

    /// IDs swiped away in the Today tab for this session only (not completed or
    /// deleted in Reminders) so the next-ranked item takes their place.
    private var skippedTodayIDs: Set<String> = []

    /// Today is capped to the top N most important items (already AI-ranked order,
    /// minus anything swiped away this session); Upcoming/Someday remain uncapped.
    var todayItems: [ReminderItem] {
        Array(bucket(.today).filter { !skippedTodayIDs.contains($0.id) }.prefix(Self.todayLimit))
    }
    var upcomingItems: [ReminderItem] { bucket(.upcoming) }
    var somedayItems: [ReminderItem] { bucket(.someday) }

    func start() async {
        if case .available = AIPrioritizer.availability {
            aiNote = nil
        } else if case .unavailable(let reason) = AIPrioritizer.availability {
            aiNote = reason
        }

        do {
            let granted = try await remindersService.requestAccess()
            guard granted else {
                loadState = .accessDenied
                return
            }
            await refresh()
        } catch {
            loadState = .error(error.localizedDescription)
        }
    }

    func refresh() async {
        loadState = .loading
        do {
            let items = try await remindersService.fetchIncompleteReminders()
            rankedReminders = await prioritizer.rank(items)
            homeIndex = 0
            skippedTodayIDs.removeAll()
            loadState = .loaded
        } catch {
            loadState = .error(error.localizedDescription)
        }
    }

    func skipHome() {
        guard !rankedReminders.isEmpty else { return }
        homeIndex = (homeIndex + 1) % rankedReminders.count
    }

    func skipToday(_ item: ReminderItem) {
        skippedTodayIDs.insert(item.id)
    }

    func complete(_ item: ReminderItem) async {
        do {
            try remindersService.setCompleted(item.id)
            removeLocally(item)
        } catch {
            loadState = .error(error.localizedDescription)
        }
    }

    func delete(_ item: ReminderItem) async {
        do {
            try remindersService.delete(item.id)
            removeLocally(item)
        } catch {
            loadState = .error(error.localizedDescription)
        }
    }

    /// Pushes the reminder's due date to (now + amount of unit). Patches the
    /// item in place rather than re-fetching/re-ranking, so it's instant; the
    /// next real refresh will naturally re-rank since the due date changed.
    func snooze(_ item: ReminderItem, amount: Int, unit: SnoozeUnit) async {
        guard let newDate = Calendar.current.date(byAdding: unit.dateComponents(amount), to: Date()) else { return }
        do {
            try remindersService.setDueDate(item.id, to: newDate)
            if let index = rankedReminders.firstIndex(where: { $0.id == item.id }) {
                rankedReminders[index] = ReminderItem(
                    id: item.id,
                    title: item.title,
                    notes: item.notes,
                    dueDate: newDate,
                    rawPriority: item.rawPriority,
                    listName: item.listName,
                    creationDate: item.creationDate
                )
            }
            if homeIndex >= rankedReminders.count {
                homeIndex = 0
            }
        } catch {
            loadState = .error(error.localizedDescription)
        }
    }

    private func removeLocally(_ item: ReminderItem) {
        rankedReminders.removeAll { $0.id == item.id }
        if homeIndex >= rankedReminders.count {
            homeIndex = 0
        }
    }

    private enum DueBucket {
        case today, upcoming, someday
    }

    private func bucket(_ b: DueBucket) -> [ReminderItem] {
        rankedReminders.filter { item in
            switch b {
            case .today:
                guard let due = item.dueDate else { return false }
                return item.isOverdue || Calendar.current.isDateInToday(due)
            case .upcoming:
                guard let due = item.dueDate else { return false }
                return !item.isOverdue && !Calendar.current.isDateInToday(due)
            case .someday:
                return item.dueDate == nil
            }
        }
    }
}
