import CryptoKit
import Foundation

/// Caches the listwise re-rank of the top candidates so relaunches don't
/// pay a model call when nothing has changed. The key covers everything the
/// ordering judgment depends on: each candidate's content *and* dates (the
/// listwise pass, unlike importance classification, deliberately sees due
/// dates), the candidate order itself, and the current calendar day — time
/// passing changes relative urgency, so a cached ordering expires at
/// midnight even if the reminders don't change.
enum TopOrderCache {
    private static let key = "RemindSort.topOrderCache"

    private static func cacheKey(for items: [ReminderItem], includesDates: Bool, now: Date) -> String {
        let day = String(Calendar.current.startOfDay(for: now).timeIntervalSince1970)
        let mode = includesDates ? "dated" : "dateless"
        let parts = items.map { item in
            let due = item.dueDate.map { String($0.timeIntervalSince1970) } ?? ""
            let created = item.creationDate.map { String($0.timeIntervalSince1970) } ?? ""
            return [item.id, item.title, item.notes ?? "", item.listName, due, created]
                .joined(separator: "\u{1}")
        }
        let digest = SHA256.hash(data: Data((parts + [day, mode]).joined(separator: "\u{2}").utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    /// Returns the cached ordering (reminder IDs, most important first) if
    /// it was produced for exactly these candidates, in the same
    /// dates-considered mode, today.
    static func cachedOrder(for items: [ReminderItem], includesDates: Bool, now: Date = Date()) -> [String]? {
        guard let stored = UserDefaults.standard.dictionary(forKey: key),
              stored["key"] as? String == cacheKey(for: items, includesDates: includesDates, now: now),
              let order = stored["order"] as? [String]
        else { return nil }
        return order
    }

    static func save(order: [String], for items: [ReminderItem], includesDates: Bool, now: Date = Date()) {
        UserDefaults.standard.set(
            ["key": cacheKey(for: items, includesDates: includesDates, now: now), "order": order],
            forKey: key
        )
    }
}
