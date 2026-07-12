import FoundationModels

/// A single reminder's urgency score. Tokens (e.g. "R3") stand in for
/// reminder IDs so the model only ever has to echo back short strings.
@Generable
struct ReminderScore: Sendable {
    @Guide(description: "The reminder's token, e.g. R0, R1, R2, exactly as given in the prompt.")
    var token: String

    @Guide(description: "Urgency/importance score from 0 (not urgent at all) to 100 (extremely urgent/important).", .range(0...100))
    var score: Int
}

/// Structured output asked of the on-device model: an independent urgency
/// score per reminder, rather than a relative ordering. Scores from separate
/// batches are directly comparable, so sorting the full set is just a plain
/// sort by score afterward — no merging of separately-ranked batches needed.
@Generable
struct UrgencyScores: Sendable {
    @Guide(description: "One score entry per reminder token given in the prompt. Every token must appear exactly once.")
    var scores: [ReminderScore]
}

/// A cheaper, faster-to-generate alternative to UrgencyScores: plain integers
/// with no per-item token field, matched back to reminders purely by position
/// (same order as the prompt list). Used only for the very first, never-been-
/// cached scoring pass, where getting *something* on screen quickly matters
/// more than the extra safety of explicit token labeling — the fuller
/// UrgencyScores pass follows shortly after in the background to refine it.
@Generable
struct QuickScores: Sendable {
    @Guide(description: "Urgency scores from 0 (not urgent) to 100 (extremely urgent), one integer per reminder, in the exact same order the reminders were listed in the prompt. Must contain exactly as many scores as reminders listed.")
    var scores: [Int]
}
