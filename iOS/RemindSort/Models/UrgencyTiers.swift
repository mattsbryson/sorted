import FoundationModels

/// The model's urgency classification for a reminder — a coarse category
/// rather than a fine-grained number. Categorical judgments are a much more
/// reliable task for a small on-device model than well-calibrated absolute
/// magnitude scores (raw 0-100 scoring tended to cluster near the top of the
/// range and over-weight incidental signals). The final numeric score is
/// computed afterward in code: reminders within the same tier are spread
/// across that tier's score band using the precise, deterministic due-date
/// heuristic — the model decides "how urgent, roughly," code decides
/// "exactly where in that ballpark."
@Generable(description: """
    Urgency tier for a reminder. critical = extremely time-sensitive or \
    high-stakes: overdue by several days, or due very soon with clear \
    real-world consequences. high = due within the next week or so, or \
    overdue but lower-stakes. medium = due within the next month, or no due \
    date but clearly meaningful from its title/notes. low = due further out \
    than a month, or no due date with routine/low-stakes content. minimal = \
    no due date, no urgency signal, minimal real-world stakes.
    """)
enum UrgencyTier: String, Sendable, CaseIterable {
    case critical
    case high
    case medium
    case low
    case minimal
}

/// A single reminder's tier. Tokens (e.g. "R3") stand in for reminder IDs so
/// the model only ever has to echo back short strings.
@Generable
struct ReminderTier: Sendable {
    @Guide(description: "The reminder's token, e.g. R0, R1, R2, exactly as given in the prompt.")
    var token: String

    @Guide(description: "The reminder's urgency tier.")
    var tier: UrgencyTier
}

@Generable
struct UrgencyTiers: Sendable {
    @Guide(description: "One tier entry per reminder token given in the prompt. Every token must appear exactly once.")
    var tiers: [ReminderTier]
}
