import Foundation

/// A ranking strategy reduced to what offline evaluation needs: a score for a
/// single logged reminder, higher meaning more important. Everything the harness
/// measures (pairwise agreement) only ever asks "does this strategy rank X above
/// Y", so a per-item score is a sufficient, ranker-agnostic interface — the same
/// shape the in-app `Ranker` protocol collapses to when diffed.
public struct Strategy: Sendable {
    public let name: String
    public let detail: String
    public let score: @Sendable (LoggedReminder) -> Double

    public init(name: String, detail: String, score: @escaping @Sendable (LoggedReminder) -> Double) {
        self.name = name
        self.detail = detail
        self.score = score
    }
}

/// The strategies evaluable purely from logged features on this branch. Adding a
/// strategy is a one-liner: append a `Strategy` here. When the Core ML and MLX
/// branches merge, each adds its own entry that runs its model over the same
/// logged features — no other harness change needed.
public enum Strategies {
    /// Deterministic time-urgency, ported from the app's `UrgencyScorer` but
    /// operating on the log's precomputed day-deltas (`dueInDays`,
    /// `createdDaysAgo`) instead of raw dates — the same weights and curves the
    /// shipping app uses for its time axis.
    static func timeUrgency(_ r: LoggedReminder) -> Double {
        guard let due = r.dueInDays else {
            let age = min(max(r.createdDaysAgo ?? 0, 0), 120)
            return 0.15 * Double(age) / 120
        }
        if due < 0 { return 0.75 + 0.25 * Double(min(-due, 14)) / 14 }
        if due == 0 { return 0.70 }
        return 0.65 * (1 - Double(min(due, 30)) / 30)
    }

    /// Importance derived from the explicit Reminders priority flag — the exact
    /// fallback `UrgencyScorer.fallbackImportance` applies when no AI judgment
    /// is available. This is the only importance signal recoverable from the
    /// logs (the AI tier isn't logged), so it's what the offline `apple`/
    /// heuristic baseline uses. RFC 5545 priority: 1–4 high, 5 medium, 6–9 low,
    /// 0 none→normal.
    static func priorityImportance(_ r: LoggedReminder) -> Double {
        switch r.priority {
        case 1...4: return 0.7   // high
        case 5: return 0.4       // medium → normal
        case 6...9: return 0.15  // low
        default: return 0.4      // none → normal (most people never set it)
        }
    }

    /// Composite score matching the app's `UrgencyScorer.score`: 0.55·time +
    /// 0.45·importance, on a 0–100 scale. This is the shipping deterministic
    /// baseline (what `apple` reduces to when Apple Intelligence is off), and
    /// the one strategy we can reproduce faithfully offline.
    public static let heuristicBaseline = Strategy(
        name: "heuristic-baseline",
        detail: "App's deterministic UrgencyScorer: 0.55·time-urgency + 0.45·priority-importance."
    ) { r in
        (0.55 * timeUrgency(r) + 0.45 * priorityImportance(r)) * 100
    }

    /// Ranks by the logged `score` the app actually showed at the time, when
    /// present. This is the *recorded* ranking — including whatever AI judgment
    /// was live then — so it's the most faithful "what the app really did"
    /// baseline, but only defined for items that carry a score. Falls back to
    /// the heuristic composite when a score is absent so it never abstains.
    public static let loggedScore = Strategy(
        name: "logged-app-score",
        detail: "Ranks by the 0–100 score the app displayed when the action was logged (heuristic fallback when absent)."
    ) { r in
        if let s = r.score { return Double(s) }
        return (0.55 * timeUrgency(r) + 0.45 * priorityImportance(r)) * 100
    }

    /// Time-only: ignores importance entirely. A useful lower/ablation bar —
    /// how much does deadline pressure alone explain the user's preferences?
    public static let timeOnly = Strategy(
        name: "time-only",
        detail: "Deadline pressure alone (0.55·time-urgency), ignoring importance."
    ) { r in
        timeUrgency(r) * 100
    }

    /// Every strategy the harness scores. Append here to add one.
    public static let all: [Strategy] = [
        heuristicBaseline,
        loggedScore,
        timeOnly,
    ]
}
