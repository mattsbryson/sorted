import CryptoKit
import Foundation

/// Persists the last AI-ranked order to disk so the (slow) on-device model
/// only has to re-run when the underlying reminders have actually changed —
/// not on every app launch or manual refresh.
enum RankingCache {
    private static let fingerprintKey = "RemindSort.rankingCache.fingerprint"
    private static let orderKey = "RemindSort.rankingCache.order"

    /// A stable content hash of everything that could affect ranking. Order-
    /// independent (sorted by id first) so re-fetching in a different order
    /// doesn't look like a change.
    static func fingerprint(for items: [ReminderItem]) -> String {
        let sorted = items.sorted { $0.id < $1.id }
        var lines: [String] = []
        lines.reserveCapacity(sorted.count)
        for item in sorted {
            let due: String = item.dueDate.map { String($0.timeIntervalSince1970) } ?? ""
            let created: String = item.creationDate.map { String($0.timeIntervalSince1970) } ?? ""
            let notes: String = item.notes ?? ""
            let priority: String = String(item.rawPriority)
            let line = [item.id, item.title, notes, due, priority, item.listName, created]
                .joined(separator: "\u{1}")
            lines.append(line)
        }
        let joined = lines.joined(separator: "\u{2}")

        let digest = SHA256.hash(data: Data(joined.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    /// Returns the cached ranked ID order if it was saved for this exact
    /// fingerprint, nil otherwise (cache miss — something changed).
    static func loadOrder(matching fingerprint: String) -> [String]? {
        let defaults = UserDefaults.standard
        guard defaults.string(forKey: fingerprintKey) == fingerprint else { return nil }
        return defaults.stringArray(forKey: orderKey)
    }

    static func save(fingerprint: String, order: [String]) {
        let defaults = UserDefaults.standard
        defaults.set(fingerprint, forKey: fingerprintKey)
        defaults.set(order, forKey: orderKey)
    }
}
