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
    /// Every Reminders list title (including empty and ignored ones), for
    /// the per-list ignore toggles in Settings. Refreshed on each load.
    private(set) var availableLists: [String] = []

    let settings = AppSettings()

    private let remindersService = RemindersService()

    /// The active ranking strategy, rebuilt from the user's `rankerKind`
    /// setting each rank so switching strategies in Settings takes effect on
    /// the next refresh. Strategies keep any loaded model in shared/static
    /// storage, so building a fresh instance per rank is cheap.
    private var prioritizer: any Ranker { RankerFactory.make(settings.rankerKind) }

    var homeReminder: ReminderItem? {
        guard !rankedReminders.isEmpty, homeIndex < rankedReminders.count else { return nil }
        return rankedReminders[homeIndex]
    }

    /// IDs swiped away in the Today tab for this session only (not completed or
    /// deleted in Reminders) so the next-ranked item takes their place.
    private var skippedTodayIDs: Set<String> = []

    /// Debounces EventKit change notifications into one quiet re-rank.
    private var databaseRefreshDebounce: Task<Void, Never>?

    /// The two reminders currently shown in the Face Off tab, and how many
    /// comparisons have been logged this session (for a small progress cue).
    private(set) var faceOffPair: (ReminderItem, ReminderItem)?
    private(set) var faceOffCount = 0

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
        let ranker = prioritizer
        let availability = await Task.detached { ranker.availability }.value
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
            let items = try await fetchVisibleReminders()
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

    /// Fetches incomplete reminders, refreshes the known list of lists (for
    /// Settings), and drops reminders in lists the user has chosen to ignore
    /// — so ignored lists are excluded everywhere, before ranking even runs.
    private func fetchVisibleReminders() async throws -> [ReminderItem] {
        let items = try await remindersService.fetchIncompleteReminders()
        availableLists = remindersService.availableListNames()
        guard !settings.ignoredLists.isEmpty else { return items }
        return items.filter { !settings.ignoredLists.contains($0.listName) }
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
        guard let items = try? await fetchVisibleReminders() else { return }
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
        refreshFaceOffPairIfStale()
    }

    /// Regenerates the Face Off pair if either reminder it references has
    /// left the ranked set (completed/deleted/edited away), so the tab never
    /// shows a reminder that no longer exists.
    private func refreshFaceOffPairIfStale() {
        guard let pair = faceOffPair else { return }
        let live = Set(rankedReminders.map(\.id))
        if !live.contains(pair.0.id) || !live.contains(pair.1.id) {
            faceOffPair = makeFaceOffPair(excluding: pair)
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

    // MARK: Face Off

    /// Ensures a pair is loaded when the tab appears. No-op if one's already
    /// showing, so switching away and back doesn't discard the current pair.
    func startFaceOff() {
        if faceOffPair == nil {
            faceOffPair = makeFaceOffPair(excluding: nil)
        }
    }

    /// Records the user's explicit judgment and advances to a fresh pair.
    func chooseFaceOff(winner: ReminderItem, loser: ReminderItem) {
        FaceOffLog.record(winner: winner, loser: loser)
        faceOffCount += 1
        faceOffPair = makeFaceOffPair(excluding: faceOffPair)
    }

    /// Swaps in a new pair without recording a judgment (the two shown were
    /// too close to call, or the user just wants different ones).
    func skipFaceOffPair() {
        faceOffPair = makeFaceOffPair(excluding: faceOffPair)
    }

    /// Draws two distinct reminders to compare. Biased toward pairs that are
    /// *near each other in the current ranking* — those are the comparisons
    /// the ranker is most uncertain about, so they're the most informative
    /// labels — while still randomized (including left/right order, so
    /// position isn't a tell) and avoiding an immediate repeat of the last
    /// pair. Returns nil if there aren't two reminders to compare.
    private func makeFaceOffPair(excluding previous: (ReminderItem, ReminderItem)?) -> (ReminderItem, ReminderItem)? {
        let items = rankedReminders
        guard items.count >= 2 else { return nil }
        let previousKey = previous.map { Set([$0.0.id, $0.1.id]) }
        let window = 4

        for _ in 0..<16 {
            let anchor = Int.random(in: 0..<items.count)
            let low = max(0, anchor - window)
            let high = min(items.count - 1, anchor + window)
            var partner = Int.random(in: low...high)
            if partner == anchor { partner = anchor < high ? anchor + 1 : anchor - 1 }
            guard partner != anchor else { continue }

            let a = items[anchor]
            let b = items[partner]
            if let previousKey, previousKey == Set([a.id, b.id]) { continue }
            return Bool.random() ? (a, b) : (b, a)
        }
        // Fallback for tiny lists where the loop couldn't find a fresh pair.
        return (items[0], items[1])
    }

    // MARK: Ranker Lab

    /// Ranks the current live reminder set through an arbitrary strategy for
    /// the read-only Ranker Lab, without touching `rankedReminders`, Home, or
    /// any log. Strips existing scores first so each strategy scores from the
    /// same neutral input rather than inheriting the active ranker's scores.
    /// Returns the strategy's ordering; empty if there's nothing to rank.
    func rankForLab(_ kind: RankerKind) async -> [ReminderItem] {
        let items = rankedReminders.map { $0.withScore(nil) }
        guard !items.isEmpty else { return [] }
        let ranker = RankerFactory.make(kind)
        return await ranker.rank(items, consideringDueDates: settings.considerDueDates)
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
        refreshFaceOffPairIfStale()
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
