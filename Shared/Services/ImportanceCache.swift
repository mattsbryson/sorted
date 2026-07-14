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
    private static let key = "Sorted.importanceCache"

    /// Different models' judgments live in different namespaces (nil = the
    /// Apple baseline's original store): a tier Llama assigned must never be
    /// served as if Qwen or Apple had judged it, and switching models in
    /// Settings shouldn't wipe another model's warm cache.
    private static func storageKey(_ namespace: String?) -> String {
        namespace.map { "\(key).\($0)" } ?? key
    }

    /// Bump when the classification prompt changes meaningfully (rubric,
    /// anchors) so every reminder is re-judged once under the new prompt —
    /// otherwise old-prompt judgments live on until content edits evict them.
    /// The ongoing drift of user-judgment calibration examples is deliberately
    /// NOT versioned: including it would evict the whole cache on every Face
    /// Off pick.
    private static let promptVersion = "v2"

    static func contentHash(for item: ReminderItem) -> String {
        let joined = [Self.promptVersion, item.id, item.title, item.notes ?? "", item.listName]
            .joined(separator: "\u{1}")
        let digest = SHA256.hash(data: Data(joined.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    /// Returns item.id -> importance for every item whose content hash is
    /// found in the cache. Items not present need a fresh classification.
    static func cachedTiers(for items: [ReminderItem], namespace: String? = nil) -> [String: ImportanceTier] {
        let stored = (UserDefaults.standard.dictionary(forKey: storageKey(namespace)) as? [String: String]) ?? [:]
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
    static func save(items: [ReminderItem], tiers: [String: ImportanceTier], namespace: String? = nil) {
        var stored: [String: String] = [:]
        stored.reserveCapacity(items.count)
        for item in items {
            if let tier = tiers[item.id] {
                stored[contentHash(for: item)] = tier.rawValue
            }
        }
        UserDefaults.standard.set(stored, forKey: storageKey(namespace))
    }
}
