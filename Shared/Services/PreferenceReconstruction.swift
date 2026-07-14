import Foundation

/// Turns the *implicit* feedback in `preferences.jsonl` into explicit pairwise
/// preference labels, so the same `RankingMetrics.pairwiseAgreement` used for
/// Face Off data can score a ranker against ordinary app usage too.
///
/// Pure and ranker-agnostic: it takes only the abstract shape of a logged
/// action (what happened, to which id, at which position, over what visible
/// ordering) and emits `winner`-should-rank-above-`loser` pairs. The CLI
/// decodes `preferences.jsonl` into this shape; the unit tests feed it
/// synthetic events. Keeping the *rule* here (not in the JSON decoder) is what
/// lets it be tested without any file I/O.
public enum PreferenceReconstruction {

    /// One implicit-feedback event, reduced to what reconstruction needs.
    public struct Action<ID: Hashable> {
        /// The logged action verb: `skip_home`, `skip_today`, `complete`,
        /// `delete`, or `snooze`.
        public let action: String
        /// The id the action was taken on.
        public let itemID: ID
        /// The item's position (0-based) in the visible ordering when acted on.
        public let position: Int
        /// The visible ranked ordering the user saw, top-first.
        public let context: [ID]

        public init(action: String, itemID: ID, position: Int, context: [ID]) {
            self.action = action
            self.itemID = itemID
            self.position = position
            self.context = context
        }
    }

    /// Reconstructs pairwise preferences from one action.
    ///
    /// The rule follows what each action reveals about the ordering the user
    /// was looking at, and *only* what it reveals — nothing is invented:
    ///
    /// - **complete / keep** (the user acted on this item *now*, in a list
    ///   sorted most-important-first): it deserved attention before everything
    ///   ranked below it that they left alone. So `item` beats each id after
    ///   it in the context. This is the strong signal — a positive engagement
    ///   with the top-ranked thing.
    /// - **skip_home / skip_today** (the user passed over the item at its
    ///   position): they preferred to deal with something else, so each item
    ///   *below* it in the context (which they moved on to consider) is judged
    ///   above the skipped one. Skips are noisier — a skip can mean "not now"
    ///   rather than "less important" — so they're weaker labels, but still
    ///   directional against the shown order.
    /// - **snooze**: like a skip — pushing an item out means, for now, other
    ///   shown items rank above it.
    /// - **delete**: the item was discarded entirely; everything still on the
    ///   list outranks it, both above and below its position.
    ///
    /// Pairs only reference ids actually present in the context, so a
    /// reconstructed pair can always be scored against a ranking of the same set.
    public static func pairs<ID: Hashable>(from action: Action<ID>) -> [RankingMetrics.LabeledPair<ID>] {
        let ctx = action.context
        guard let idx = ctx.firstIndex(of: action.itemID) else { return [] }

        switch action.action {
        case "complete", "keep":
            // The acted item beats everything the user left below it.
            return ctx[(idx + 1)...].map { .init(winner: action.itemID, loser: $0) }

        case "skip_home", "skip_today", "snooze":
            // Everything the user moved on to below outranks the skipped item.
            return ctx[(idx + 1)...].map { .init(winner: $0, loser: action.itemID) }

        case "delete":
            // The removed item loses to every other item still on the list.
            return ctx.enumerated()
                .filter { $0.offset != idx }
                .map { .init(winner: $0.element, loser: action.itemID) }

        default:
            return []
        }
    }
}
