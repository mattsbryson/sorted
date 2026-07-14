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

    /// Prunes bracket members and regenerates the Face Off pair if any
    /// reminder involved has left the ranked set (completed/deleted/edited
    /// away), so the tab never shows a reminder that no longer exists.
    private func refreshFaceOffPairIfStale() {
        let live = Set(rankedReminders.map(\.id))
        faceOffRound.removeAll { !live.contains($0.id) }
        faceOffWinners.removeAll { !live.contains($0.id) }
        guard let pair = faceOffPair else { return }
        if !live.contains(pair.0.id) || !live.contains(pair.1.id) {
            faceOffPair = nextFaceOffPair()
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

    /// Face Off runs as a **single-elimination bracket** over a sampled pool
    /// of reminders: round-one pairs are random, but winners advance to face
    /// other winners, so successive comparisons are between increasingly
    /// important reminders — the highest-signal training labels, near the top
    /// of the importance scale where ranking accuracy matters most. When a
    /// bracket resolves, a fresh pool is sampled and a new bracket begins.
    ///
    /// A pair is **never asked twice**: everything already compared — in the
    /// on-device log (imported history included) or skipped this session — is
    /// excluded from pairing. Left/right order is randomized so position
    /// isn't a tell.

    /// Sampled pool size per bracket: 16 → at most 15 comparisons to a
    /// champion, a comfortable single sitting.
    private static let faceOffBracketSize = 16

    /// Reminders awaiting a comparison in the current round, and winners
    /// promoted to the next round.
    private var faceOffRound: [ReminderItem] = []
    private var faceOffWinners: [ReminderItem] = []
    /// Every pair already asked: seeded from the log at bracket seed time,
    /// grown by this session's picks and skips.
    private var faceOffComparedPairs: Set<String> = []

    /// Ensures a pair is loaded when the tab appears. No-op if one's already
    /// showing, so switching away and back doesn't discard the current pair.
    func startFaceOff() {
        if faceOffPair == nil {
            faceOffPair = nextFaceOffPair()
        }
    }

    /// Records the user's explicit judgment, advances the winner in the
    /// bracket, and shows the next pair.
    func chooseFaceOff(winner: ReminderItem, loser: ReminderItem) {
        FaceOffLog.record(winner: winner, loser: loser)
        faceOffComparedPairs.insert(FaceOffLog.pairKey(winner.id, loser.id))
        faceOffCount += 1
        faceOffWinners.append(winner)
        faceOffPair = nextFaceOffPair()
    }

    /// Swaps in a new pair without recording a judgment (the two shown were
    /// too close to call). Neither advances; the pair won't be asked again
    /// this session.
    func skipFaceOffPair() {
        if let pair = faceOffPair {
            faceOffComparedPairs.insert(FaceOffLog.pairKey(pair.0.id, pair.1.id))
        }
        faceOffPair = nextFaceOffPair()
    }

    /// Draws the next uncompared pair: from the current round; else by
    /// promoting winners into a new round; else by seeding a fresh bracket.
    /// Returns nil only when there's nothing left to compare (fewer than two
    /// reminders, or every pair in two fresh samples was already judged).
    private func nextFaceOffPair() -> (ReminderItem, ReminderItem)? {
        guard rankedReminders.count >= 2 else { return nil }

        for _ in 0..<3 {
            if let pair = drawFaceOffPair() { return pair }
            // Round exhausted: winners (plus any odd leftover, which advances
            // by bye) become the next round.
            let promoted = faceOffWinners + faceOffRound
            faceOffWinners = []
            if promoted.count >= 2 {
                faceOffRound = promoted.shuffled()
                if let pair = drawFaceOffPair() { return pair }
            }
            // Bracket resolved (or ran dry): sample a fresh pool.
            seedFaceOffBracket()
        }
        return nil
    }

    /// Takes the next reminder in the round and pairs it with the first
    /// round-mate it hasn't already faced. A reminder that has faced everyone
    /// left advances without a fresh comparison.
    private func drawFaceOffPair() -> (ReminderItem, ReminderItem)? {
        while faceOffRound.count >= 2 {
            let a = faceOffRound.removeFirst()
            if let index = faceOffRound.firstIndex(where: { candidate in
                !faceOffComparedPairs.contains(FaceOffLog.pairKey(a.id, candidate.id))
            }) {
                let b = faceOffRound.remove(at: index)
                return Bool.random() ? (a, b) : (b, a)
            }
            faceOffWinners.append(a)
        }
        return nil
    }

    /// Samples a fresh pool across the whole ranking and reloads the asked-
    /// pair history from the log (so freshly imported judgments are honored).
    /// The log read is synchronous but bounded (`TrainingLog.maxFileBytes`)
    /// and happens once per bracket, not per pair.
    private func seedFaceOffBracket() {
        faceOffComparedPairs.formUnion(FaceOffLog.comparedPairKeys())
        faceOffRound = Array(rankedReminders.shuffled().prefix(Self.faceOffBracketSize))
        faceOffWinners = []
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
