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
        static let rankerLabEnabled = "Sorted.settings.rankerLabEnabled"
        static let ignoredLists = "Sorted.settings.ignoredLists"
        static let rankerKind = "Sorted.settings.rankerKind"
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

    /// When true, a "Ranker Lab" tab appears that runs the live reminder set
    /// through two selectable strategies and shows them side by side with rank
    /// deltas and a rank-agreement (Kendall tau) number. Read-only — it never
    /// mutates reminders. Off by default: a power-user inspection tool for
    /// comparing ranking strategies, not part of the everyday flow, mirroring
    /// `faceOffEnabled`.
    var rankerLabEnabled: Bool {
        didSet { UserDefaults.standard.set(rankerLabEnabled, forKey: Keys.rankerLabEnabled) }
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

    /// Which ranking strategy is active. Lets the experimental Core ML and MLX
    /// rankers be A/B'd against the Apple baseline at runtime. Defaults to the
    /// shipping baseline so a fresh install behaves exactly as before.
    var rankerKind: RankerKind {
        didSet { UserDefaults.standard.set(rankerKind.rawValue, forKey: Keys.rankerKind) }
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
        rankerLabEnabled = defaults.bool(forKey: Keys.rankerLabEnabled)
        ignoredLists = Set(defaults.stringArray(forKey: Keys.ignoredLists) ?? [])
        rankerKind = defaults.string(forKey: Keys.rankerKind).flatMap(RankerKind.init) ?? .apple
    }
}
