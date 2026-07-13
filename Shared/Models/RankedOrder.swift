import FoundationModels

/// The model's listwise ordering of a set of reminders, most important
/// first. Used by the top-of-list re-rank pass: coarse importance tiers are
/// judged per item (a reliable task in isolation), but *fine* ordering is a
/// comparative judgment — small on-device models rank a handful of items
/// far better when they see them side by side than when scoring each alone.
/// Tokens (e.g. "R3") stand in for reminder IDs so the model only ever has
/// to echo back short strings.
@Generable
struct RankedOrder: Sendable {
    @Guide(description: """
        Every reminder token from the prompt (e.g. R0, R1, R2), reordered \
        most important first. Each token must appear exactly once.
        """)
    var tokens: [String]
}
