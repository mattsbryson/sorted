import FoundationModels

/// Structured output asked of the on-device model: reminder tokens ordered from
/// most to least important. Tokens (e.g. "R3") stand in for reminder IDs so the
/// model only ever has to echo back short strings, not full UUIDs.
@Generable
struct PriorityRanking: Sendable {
    @Guide(description: "Reminder tokens such as R0, R1, R2 ordered from most important/urgent first to least important last. Every token given in the prompt must appear exactly once.")
    var orderedTokens: [String]
}
