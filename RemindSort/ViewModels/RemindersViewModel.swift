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

    /// Today is capped to the top N most important items (already AI-ranked order);
    /// Upcoming/Someday remain uncapped.
    var todayItems: [ReminderItem] { Array(bucket(.today).prefix(Self.todayLimit)) }
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
            loadState = .loaded
        } catch {
            loadState = .error(error.localizedDescription)
        }
    }

    func skipHome() {
        guard !rankedReminders.isEmpty else { return }
        homeIndex = (homeIndex + 1) % rankedReminders.count
    }

    func complete(_ item: ReminderItem) async {
        do {
            try remindersService.setCompleted(item.id)
            rankedReminders.removeAll { $0.id == item.id }
            if homeIndex >= rankedReminders.count {
                homeIndex = 0
            }
        } catch {
            loadState = .error(error.localizedDescription)
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
