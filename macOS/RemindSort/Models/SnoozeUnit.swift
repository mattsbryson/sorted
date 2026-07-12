import Foundation

enum SnoozeUnit: String, CaseIterable, Identifiable, Sendable {
    case day = "Day"
    case month = "Month"
    case year = "Year"

    var id: String { rawValue }

    func pluralized(for amount: Int) -> String {
        amount == 1 ? rawValue : rawValue + "s"
    }

    var dateComponents: (Int) -> DateComponents {
        switch self {
        case .day: return { DateComponents(day: $0) }
        case .month: return { DateComponents(month: $0) }
        case .year: return { DateComponents(year: $0) }
        }
    }
}
