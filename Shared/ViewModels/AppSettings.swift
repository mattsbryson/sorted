import Foundation
import Observation

/// User-configurable preferences, persisted via UserDefaults.
@MainActor
@Observable
final class AppSettings {
    private enum Keys {
        static let todayLimit = "RemindSort.settings.todayLimit"
        static let showUrgencyScore = "RemindSort.settings.showUrgencyScore"
        static let considerDueDates = "RemindSort.settings.considerDueDates"
        static let preferenceLogging = "RemindSort.settings.preferenceLogging"
        static let faceOffEnabled = "RemindSort.settings.faceOffEnabled"
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
    }
}
