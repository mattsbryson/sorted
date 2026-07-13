import CryptoKit
import Foundation

/// Persists each reminder's AI importance classification, keyed by a hash of
/// exactly the content the model judges: title, notes, and list. Due date,
/// priority, and creation date are deliberately excluded — importance is
/// date-blind, so snoozing or rescheduling never forces a re-classification;
/// only editing what the reminder *is* does. The time component of the score
/// isn't cached at all: it's recomputed from dates on every rank, so scores
/// can't go stale as due dates approach.
enum ImportanceCache {
    private static let key = "RemindSort.importanceCache"
    /// UserDefaults key of the pre-redesign score cache, cleared on first save.
    private static let legacyScoreKey = "RemindSort.scoreCache"

    static func contentHash(for item: ReminderItem) -> String {
        let joined = [item.id, item.title, item.notes ?? "", item.listName]
            .joined(separator: "\u{1}")
        let digest = SHA256.hash(data: Data(joined.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    /// Returns item.id -> importance for every item whose content hash is
    /// found in the cache. Items not present need a fresh classification.
    static func cachedTiers(for items: [ReminderItem]) -> [String: ImportanceTier] {
        let stored = (UserDefaults.standard.dictionary(forKey: key) as? [String: String]) ?? [:]
        var result: [String: ImportanceTier] = [:]
        result.reserveCapacity(items.count)
        for item in items {
            if let raw = stored[contentHash(for: item)], let tier = ImportanceTier(rawValue: raw) {
                result[item.id] = tier
            }
        }
        return result
    }

    /// Rewrites the cache to hold exactly the given items' AI-classified
    /// tiers — nothing more, so it can never grow unbounded. Callers must
    /// pass only genuinely AI-derived tiers: fallback tiers are never saved,
    /// so an item the model failed on gets retried next refresh instead of
    /// freezing its fallback forever.
    static func save(items: [ReminderItem], tiers: [String: ImportanceTier]) {
        var stored: [String: String] = [:]
        stored.reserveCapacity(items.count)
        for item in items {
            if let tier = tiers[item.id] {
                stored[contentHash(for: item)] = tier.rawValue
            }
        }
        UserDefaults.standard.set(stored, forKey: key)
        UserDefaults.standard.removeObject(forKey: legacyScoreKey)
    }
}
