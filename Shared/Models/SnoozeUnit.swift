import Foundation

enum SnoozeUnit: String, CaseIterable, Identifiable, Sendable {
    case day = "Day"
    case week = "Week"
    case month = "Month"

    var id: String { rawValue }

    func pluralized(for amount: Int) -> String {
        amount == 1 ? rawValue : rawValue + "s"
    }

    var dateComponents: (Int) -> DateComponents {
        switch self {
        case .day: return { DateComponents(day: $0) }
        case .week: return { DateComponents(day: $0 * 7) }
        case .month: return { DateComponents(month: $0) }
        }
    }
}
