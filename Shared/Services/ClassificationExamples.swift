import Foundation

/// Shared few-shot content for the importance-classification prompts, used
/// verbatim by both the Apple (`AIPrioritizer`) and MLX (`MLXRanker`) arms so
/// their rubrics can't drift apart.
///
/// Two pieces:
/// - **Tier anchors**: four canonical examples, one per tier, that pin the
///   rubric's scale. Without anchors, small models judging in the abstract
///   drift toward calling everything "high".
/// - **User judgments**: a handful of the user's own most recent Face Off
///   picks, phrased as relative examples. This personalizes ranking *today*,
///   before the trained Core ML model has enough data — the same log feeds
///   both.
enum ClassificationExamples {
    /// One anchor per tier, matching `ImportanceTier`'s definitions.
    static let tierAnchors = """
    Calibration examples: "Schedule follow-up for abnormal blood test" = \
    critical. "Finish the quarterly report" = high. "Buy laundry detergent" \
    = normal. "Someday: try that new ramen place" = low.
    """

    /// How many of the user's judgments to include. Enough to convey taste,
    /// small enough to stay a fraction of the batch prompt (the Apple arm has
    /// a ~4096-token context shared with 15 reminder lines).
    static let judgmentLimit = 5

    /// The user's most recent explicit Face Off picks as prompt lines, or ""
    /// when none are logged. Titles are what the model can generalize from;
    /// truncated defensively so one long reminder can't eat the budget.
    static func userJudgmentsClause() -> String {
        let judgments = FaceOffLog.recentJudgments(limit: judgmentLimit)
        guard !judgments.isEmpty else { return "" }
        let lines = judgments.map { judgment in
            "- \"\(clip(judgment.winnerTitle))\" matters more than \"\(clip(judgment.loserTitle))\""
        }
        return "\nThis user's own explicit judgments, for calibration "
            + "(more important first):\n" + lines.joined(separator: "\n")
    }

    private static func clip(_ text: String) -> String {
        text.count > 80 ? String(text.prefix(80)) + "…" : text
    }
}
