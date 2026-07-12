import CryptoKit
import Foundation

/// Persists each reminder's urgency score to disk, keyed by a content hash —
/// not by reminder ID, and not as one all-or-nothing snapshot of the whole
/// list. This is deliberately simple: no ordering to reconstruct, no merging
/// of separately-ranked batches. A reminder whose content hash matches a
/// previous run reuses that score; anything else gets (re-)scored. Saving
/// always rewrites the cache scoped to exactly the current item set, so
/// stale entries for completed/deleted/edited-away reminders never linger.
enum ScoreCache {
    private static let key = "RemindSort.scoreCache"

    /// A stable content hash of everything about this reminder that could
    /// affect its urgency score.
    static func contentHash(for item: ReminderItem) -> String {
        let due = item.dueDate.map { String($0.timeIntervalSince1970) } ?? ""
        let created = item.creationDate.map { String($0.timeIntervalSince1970) } ?? ""
        let notes = item.notes ?? ""
        let priority = String(item.rawPriority)
        let joined = [item.id, item.title, notes, due, priority, item.listName, created]
            .joined(separator: "\u{1}")
        let digest = SHA256.hash(data: Data(joined.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    /// True only if the cache has never been populated at all (fresh install,
    /// or nothing has ever been scored yet) — distinct from "everything in
    /// the current fetch happens to be new," which still counts as a normal
    /// (non-first) pass.
    static func hasAnyCachedScores() -> Bool {
        let stored = (UserDefaults.standard.dictionary(forKey: key) as? [String: Int]) ?? [:]
        return !stored.isEmpty
    }

    /// Returns item.id -> score for every item whose content hash is found
    /// in the cache. Items not present here need a fresh score.
    static func cachedScores(for items: [ReminderItem]) -> [String: Int] {
        let stored = (UserDefaults.standard.dictionary(forKey: key) as? [String: Int]) ?? [:]
        var result: [String: Int] = [:]
        result.reserveCapacity(items.count)
        for item in items {
            if let score = stored[contentHash(for: item)] {
                result[item.id] = score
            }
        }
        return result
    }

    /// Rewrites the cache to hold exactly the given items' hashes and scores
    /// — nothing more, nothing less, so it can never grow unbounded.
    static func save(items: [ReminderItem], scores: [String: Int]) {
        var stored: [String: Int] = [:]
        stored.reserveCapacity(items.count)
        for item in items {
            if let score = scores[item.id] {
                stored[contentHash(for: item)] = score
            }
        }
        UserDefaults.standard.set(stored, forKey: key)
    }
}
