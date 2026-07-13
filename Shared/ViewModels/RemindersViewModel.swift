import Foundation
import Observation

enum LoadState: Equatable {
    case idle
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
    /// A failed user action (complete/delete/snooze). Shown as an alert
    /// over the intact UI — unlike `loadState = .error`, which replaces the
    /// whole screen and is reserved for failures to load at all.
    private(set) var actionError: String?

    let settings = AppSettings()

    private let remindersService = RemindersService()
    private let prioritizer = AIPrioritizer()

    var homeReminder: ReminderItem? {
        guard !rankedReminders.isEmpty, homeIndex < rankedReminders.count else { return nil }
        return rankedReminders[homeIndex]
    }

    /// IDs swiped away in the Today tab for this session only (not completed or
    /// deleted in Reminders) so the next-ranked item takes their place.
    private var skippedTodayIDs: Set<String> = []

    /// Debounces EventKit change notifications into one quiet re-rank.
    private var databaseRefreshDebounce: Task<Void, Never>?

    /// Today is simply the top N most important reminders overall, in
    /// AI-ranked order, minus anything swiped away this session — no due-date
    /// filter, so it's a "what should I do next" shortlist regardless of when
    /// things are due. N is user-configurable in Settings. Upcoming/Someday
    /// remain uncapped and still filter by due date.
    var todayItems: [ReminderItem] {
        Array(rankedReminders.filter { !skippedTodayIDs.contains($0.id) }.prefix(settings.todayLimit))
    }
    var upcomingItems: [ReminderItem] { bucket(.upcoming) }
    var somedayItems: [ReminderItem] { bucket(.someday) }

    func start() async {
        // SystemLanguageModel.default.availability can take a noticeable
        // moment on its first access after launch, and this method runs on
        // the main actor — checked inline it blocked the first frame,
        // leaving the window blank (black in dark mode) until it returned.
        // A detached task keeps it off the main thread so the loading
        // spinner renders and animates immediately.
        let availability = await Task.detached { AIPrioritizer.availability }.value
        if case .unavailable(let reason) = availability {
            aiNote = reason
        } else {
            aiNote = nil
        }

        do {
            let granted = try await remindersService.requestAccess()
            guard granted else {
                loadState = .accessDenied
                return
            }
            remindersService.observeChanges { [weak self] in
                self?.scheduleDatabaseRefresh()
            }
            await refresh()
        } catch {
            loadState = .error(error.localizedDescription)
        }
    }

    func refresh() async {
        // Ranking is synchronous (single up-front classification pass, no
        // background refinement), so the loading screen covers it whenever
        // there's actually something new/changed to classify; if everything's
        // cached, rank(_:) returns essentially instantly and this just
        // flashes through.
        loadState = .loading
        do {
            let items = try await remindersService.fetchIncompleteReminders()
            rankedReminders = await prioritizer.rank(
                items,
                consideringDueDates: settings.considerDueDates
            )
            homeIndex = 0
            skippedTodayIDs.removeAll()
            loadState = .loaded
        } catch {
            loadState = .error(error.localizedDescription)
        }
    }

    /// EventKit fires bursts of change notifications (a single edit can
    /// produce several, and this app's own writes fire them too), so
    /// changes are debounced into one quiet re-rank.
    private func scheduleDatabaseRefresh() {
        databaseRefreshDebounce?.cancel()
        databaseRefreshDebounce = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(1.5)) } catch { return }
            await self?.quietRefresh()
        }
    }

    /// Re-fetches and re-ranks without touching `loadState` — external
    /// changes (a reminder added in Reminders.app, an iCloud sync) flow in
    /// without flashing the loading screen or disturbing what the user is
    /// doing. New reminders get classified as part of `rank(_:)`; everything
    /// already cached is instant. The reminder showing on Home keeps its
    /// spot if it still exists after the re-rank.
    private func quietRefresh() async {
        // Only reconcile on top of a settled UI; a user-initiated refresh
        // already fetches the latest state itself.
        guard loadState == .loaded else { return }
        guard let items = try? await remindersService.fetchIncompleteReminders() else { return }
        let homeID = homeReminder?.id
        let ranked = await prioritizer.rank(items, consideringDueDates: settings.considerDueDates)
        guard loadState == .loaded else { return }
        rankedReminders = ranked
        skippedTodayIDs.formIntersection(Set(ranked.map(\.id)))
        if let homeID, let index = ranked.firstIndex(where: { $0.id == homeID }) {
            homeIndex = index
        } else if homeIndex >= ranked.count {
            homeIndex = 0
        }
    }

    /// All feedback logging funnels through here so the Settings toggle is
    /// enforced in exactly one place.
    private func logPreference(
        action: String,
        item: ReminderItem,
        position: Int,
        context: [ReminderItem],
        snoozeDays: Int? = nil
    ) {
        guard settings.preferenceLogging else { return }
        PreferenceLog.record(
            action: action,
            item: item,
            position: position,
            context: context,
            snoozeDays: snoozeDays
        )
    }

    func skipHome() {
        guard !rankedReminders.isEmpty else { return }
        logPreference(
            action: "skip_home",
            item: rankedReminders[homeIndex],
            position: homeIndex,
            context: rankedReminders
        )
        homeIndex = (homeIndex + 1) % rankedReminders.count
    }

    func skipToday(_ item: ReminderItem) {
        // Context is the Today list as the user saw it, not the global
        // ranking — the skip is a judgment about that visible ordering.
        let visible = todayItems
        logPreference(
            action: "skip_today",
            item: item,
            position: visible.firstIndex { $0.id == item.id } ?? 0,
            context: visible
        )
        skippedTodayIDs.insert(item.id)
    }

    func complete(_ item: ReminderItem) async {
        do {
            try remindersService.setCompleted(item.id)
            logPreference(
                action: "complete",
                item: item,
                position: rankedReminders.firstIndex { $0.id == item.id } ?? 0,
                context: rankedReminders
            )
            removeLocally(item)
        } catch {
            actionError = error.localizedDescription
        }
    }

    func delete(_ item: ReminderItem) async {
        do {
            try remindersService.delete(item.id)
            logPreference(
                action: "delete",
                item: item,
                position: rankedReminders.firstIndex { $0.id == item.id } ?? 0,
                context: rankedReminders
            )
            removeLocally(item)
        } catch {
            actionError = error.localizedDescription
        }
    }

    func dismissActionError() {
        actionError = nil
    }

    /// Pushes the reminder's due date to (now + amount of unit). Patches the
    /// item in place rather than re-fetching/re-ranking, so it's instant; the
    /// next real refresh will naturally re-rank since the due date changed.
    func snooze(_ item: ReminderItem, amount: Int, unit: SnoozeUnit) async {
        guard let newDate = Calendar.current.date(byAdding: unit.dateComponents(amount), to: Date()) else { return }
        do {
            try remindersService.setDueDate(item.id, to: newDate)
            logPreference(
                action: "snooze",
                item: item,
                position: rankedReminders.firstIndex { $0.id == item.id } ?? 0,
                context: rankedReminders,
                snoozeDays: Calendar.current.dateComponents(
                    [.day],
                    from: Calendar.current.startOfDay(for: Date()),
                    to: Calendar.current.startOfDay(for: newDate)
                ).day
            )
            if let index = rankedReminders.firstIndex(where: { $0.id == item.id }) {
                rankedReminders[index] = ReminderItem(
                    id: item.id,
                    title: item.title,
                    notes: item.notes,
                    dueDate: newDate,
                    rawPriority: item.rawPriority,
                    listName: item.listName,
                    creationDate: item.creationDate,
                    score: item.score
                )
            }
            if homeIndex >= rankedReminders.count {
                homeIndex = 0
            }
        } catch {
            actionError = error.localizedDescription
        }
    }

    private func removeLocally(_ item: ReminderItem) {
        rankedReminders.removeAll { $0.id == item.id }
        if homeIndex >= rankedReminders.count {
            homeIndex = 0
        }
    }

    private enum DueBucket {
        case upcoming, someday
    }

    private func bucket(_ b: DueBucket) -> [ReminderItem] {
        rankedReminders.filter { item in
            switch b {
            case .upcoming:
                guard let due = item.dueDate else { return false }
                return !item.isOverdue && !Calendar.current.isDateInToday(due)
            case .someday:
                return item.dueDate == nil
            }
        }
    }
}
