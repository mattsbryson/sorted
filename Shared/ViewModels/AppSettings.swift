import Foundation
import Observation

/// User-configurable preferences, persisted via UserDefaults.
@MainActor
@Observable
final class AppSettings {
    private enum Keys {
        static let todayLimit = "Sorted.settings.todayLimit"
        static let showUrgencyScore = "Sorted.settings.showUrgencyScore"
        static let considerDueDates = "Sorted.settings.considerDueDates"
        static let preferenceLogging = "Sorted.settings.preferenceLogging"
        static let faceOffEnabled = "Sorted.settings.faceOffEnabled"
        static let ignoredLists = "Sorted.settings.ignoredLists"
    }

    static let todayLimitRange = 1...20

    var todayLimit: Int {
        didSet {
            let clamped = min(Self.todayLimitRange.upperBound, max(Self.todayLimitRange.lowerBound, todayLimit))
            if clamped != todayLimit {
                todayLimit = clamped
                return
            }
            UserDefaults.standard.set(todayLimit, forKey: Keys.todayLimit)
        }
    }

    var showUrgencyScore: Bool {
        didSet { UserDefaults.standard.set(showUrgencyScore, forKey: Keys.showUrgencyScore) }
    }

    /// When false, ranking ignores the time axis entirely (due dates,
    /// overdue status, and the undated-item neglect bonus) and sorts purely
    /// by importance. On by default.
    var considerDueDates: Bool {
        didSet { UserDefaults.standard.set(considerDueDates, forKey: Keys.considerDueDates) }
    }

    /// When true (default), ranking-feedback events (skip/complete/snooze/
    /// delete plus the ranked context) are appended to the on-device
    /// preference log — future training data for a custom ranking model.
    var preferenceLogging: Bool {
        didSet { UserDefaults.standard.set(preferenceLogging, forKey: Keys.preferenceLogging) }
    }

    /// When true, a "Face Off" tab appears where the user picks the more
    /// important of two reminders, logging explicit pairwise training data
    /// (`FaceOffLog`). Off by default — it's a power-user data-collection
    /// tab, not part of the everyday flow.
    var faceOffEnabled: Bool {
        didSet { UserDefaults.standard.set(faceOffEnabled, forKey: Keys.faceOffEnabled) }
    }

    /// Titles of Reminders lists the user has chosen to hide. Reminders in
    /// these lists are filtered out before ranking, so they appear nowhere
    /// in the app. Keyed by list title (EventKit's stable identifiers aren't
    /// exposed for lists here, and titles are what the user recognizes).
    var ignoredLists: Set<String> {
        didSet {
            UserDefaults.standard.set(Array(ignoredLists), forKey: Keys.ignoredLists)
        }
    }

    func isListIgnored(_ list: String) -> Bool { ignoredLists.contains(list) }

    func setList(_ list: String, ignored: Bool) {
        if ignored {
            ignoredLists.insert(list)
        } else {
            ignoredLists.remove(list)
        }
    }

    init() {
        let defaults = UserDefaults.standard
        if let stored = defaults.object(forKey: Keys.todayLimit) as? Int {
            todayLimit = stored
        } else {
            todayLimit = 5
        }
        showUrgencyScore = defaults.bool(forKey: Keys.showUrgencyScore)
        considerDueDates = (defaults.object(forKey: Keys.considerDueDates) as? Bool) ?? true
        preferenceLogging = (defaults.object(forKey: Keys.preferenceLogging) as? Bool) ?? true
        faceOffEnabled = defaults.bool(forKey: Keys.faceOffEnabled)
        ignoredLists = Set(defaults.stringArray(forKey: Keys.ignoredLists) ?? [])
    }
}
