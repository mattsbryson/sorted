import Foundation
import Observation

/// User-configurable preferences, persisted via UserDefaults.
@MainActor
@Observable
final class AppSettings {
    private enum Keys {
        static let todayLimit = "RemindSort.settings.todayLimit"
        static let showUrgencyScore = "RemindSort.settings.showUrgencyScore"
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

    init() {
        let defaults = UserDefaults.standard
        if let stored = defaults.object(forKey: Keys.todayLimit) as? Int {
            todayLimit = stored
        } else {
            todayLimit = 5
        }
        showUrgencyScore = defaults.bool(forKey: Keys.showUrgencyScore)
    }
}
