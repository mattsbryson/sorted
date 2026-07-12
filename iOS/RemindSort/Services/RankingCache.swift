import CryptoKit
import Foundation

/// Persists the last AI-ranked order to disk **per reminder**, so a refresh
/// only has to rank reminders that are actually new or changed — unchanged
/// reminders keep their previously established position without ever
/// touching the model again.
enum RankingCache {
    private static let hashesKey = "RemindSort.rankingCache.itemHashes"
    private static let orderKey = "RemindSort.rankingCache.order"

    struct Diff {
        /// Previously ranked items that are unchanged, in their previous
        /// relative order.
        let unchanged: [ReminderItem]
        /// New reminders, or ones whose ranking-relevant fields changed —
        /// these are the only ones that need a fresh AI ranking pass.
        let toRank: [ReminderItem]
    }

    /// A stable content hash of everything about this reminder that could
    /// affect its ranking.
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

    /// Splits the current items into "unchanged, reuse previous position"
    /// and "new/changed, needs (re-)ranking" by comparing against the last
    /// saved per-item hashes. Anything no longer present (completed/deleted
    /// elsewhere) is simply dropped, not carried forward.
    static func diff(against items: [ReminderItem]) -> Diff {
        let defaults = UserDefaults.standard
        let savedHashes = defaults.dictionary(forKey: hashesKey) as? [String: String] ?? [:]
        let savedOrder = defaults.stringArray(forKey: orderKey) ?? []

        let byID = Dictionary(uniqueKeysWithValues: items.map { ($0.id, $0) })

        var toRank: [ReminderItem] = []
        var unchangedIDs = Set<String>()
        for item in items {
            if savedHashes[item.id] == contentHash(for: item) {
                unchangedIDs.insert(item.id)
            } else {
                toRank.append(item)
            }
        }

        let unchanged = savedOrder.compactMap { id in
            unchangedIDs.contains(id) ? byID[id] : nil
        }

        return Diff(unchanged: unchanged, toRank: toRank)
    }

    /// Saves the final ranked order along with each item's current content
    /// hash, so the next diff() can tell exactly what changed.
    static func save(rankedItems: [ReminderItem]) {
        let defaults = UserDefaults.standard
        var hashes: [String: String] = [:]
        hashes.reserveCapacity(rankedItems.count)
        for item in rankedItems {
            hashes[item.id] = contentHash(for: item)
        }
        defaults.set(hashes, forKey: hashesKey)
        defaults.set(rankedItems.map(\.id), forKey: orderKey)
    }
}
