import FoundationModels

/// The model's judgment of a reminder's real-world stakes — how much it
/// matters that this task gets done — judged from content alone (title,
/// notes, list). Deliberately date-blind: time urgency is computed
/// deterministically in code (`UrgencyScorer`) from the due date the app
/// already knows precisely, rather than asking a small on-device model to
/// fold date arithmetic it's unreliable at into its judgment. Splitting the
/// axes this way also means an importance judgment stays valid until the
/// reminder's content changes, no matter how much time passes or how often
/// it's rescheduled.
@Generable(description: """
    Real-world importance of a task, judged only from what the task is — \
    never from when it's due. critical = serious consequences if it never \
    happened: health, safety, legal or financial obligations, hard \
    commitments made to other people. high = clearly matters: work \
    deliverables, family needs, appointments, anything someone is counting \
    on. normal = ordinary tasks, errands, and chores worth doing. low = \
    optional, trivial, or someday/maybe items with no real consequence if \
    skipped.
    """)
enum ImportanceTier: String, Sendable, CaseIterable {
    case critical
    case high
    case normal
    case low
}

/// A single reminder's importance. Tokens (e.g. "R3") stand in for reminder
/// IDs so the model only ever has to echo back short strings.
@Generable
struct ReminderImportance: Sendable {
    @Guide(description: "The reminder's token, e.g. R0, R1, R2, exactly as given in the prompt.")
    var token: String

    @Guide(description: "The reminder's importance tier.")
    var tier: ImportanceTier
}

@Generable
struct ImportanceTiers: Sendable {
    @Guide(description: "One entry per reminder token given in the prompt. Every token must appear exactly once.")
    var entries: [ReminderImportance]
}
