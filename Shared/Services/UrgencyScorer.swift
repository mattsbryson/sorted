import Foundation

/// Turns an importance tier plus a reminder's dates into the final 0-100
/// urgency score, entirely deterministically.
///
/// Ranking is split across two independent axes, each handled by the part of
/// the system that's actually good at it:
///
/// - **Importance** (real-world stakes) comes from the on-device model,
///   judged from content alone — the one thing code can't know.
/// - **Time urgency** is computed here from the due and creation dates with
///   precise date math — the one thing a small on-device model can't do
///   reliably.
///
/// Because the time component is recomputed on every rank, a reminder
/// drifting toward its due date climbs the ranking day by day with no model
/// call and no cache invalidation, and a same-day reminder can never rank
/// below a next-week one of equal importance — the failure modes of asking
/// the model for a single combined judgment.
enum UrgencyScorer {
    /// Time urgency dominates slightly: an overdue trivial errand should
    /// surface, but a genuinely important task due this week should still
    /// outrank it (see the weights working together in `score`).
    private static let timeWeight = 0.55
    private static let importanceWeight = 0.45

    /// With `consideringDueDates` off (a user setting), the time axis is
    /// dropped entirely and importance alone fills the 0-100 scale — the
    /// user has asked for stakes-only ranking, so due dates, overdue status,
    /// and the undated neglect bonus all stop mattering.
    static func score(
        importance: ImportanceTier,
        item: ReminderItem,
        now: Date = Date(),
        consideringDueDates: Bool = true
    ) -> Int {
        let combined: Double
        if consideringDueDates {
            combined = timeWeight * timeUrgency(for: item, now: now)
                + importanceWeight * weight(of: importance)
        } else {
            combined = weight(of: importance)
        }
        return Int((combined * 100).rounded())
    }

    static func weight(of tier: ImportanceTier) -> Double {
        switch tier {
        case .critical: 1.0
        case .high: 0.7
        case .normal: 0.4
        case .low: 0.15
        }
    }

    /// Importance derived from the explicit Reminders priority flag, used
    /// only when no AI judgment is available (Apple Intelligence off, a
    /// model call failing, or an item omitted from the model's response).
    /// An unset flag reads as normal, not low — most people never set it.
    static func fallbackImportance(for item: ReminderItem) -> ImportanceTier {
        switch item.priorityLevel {
        case .high: .high
        case .medium: .normal
        case .low: .low
        case .none: .normal
        }
    }

    /// 0...1, from calendar-day date math (midnight to midnight, so a
    /// reminder due at 11pm today still counts as "today", matching
    /// `ReminderItem.isOverdue`):
    ///
    /// - Overdue: 0.75, plus a small bonus growing with overdue days, capped
    ///   at two weeks — being overdue at all is the strong signal, and the
    ///   cap keeps a long-abandoned item from drowning out everything else.
    /// - Due today: 0.70, always above any future due date.
    /// - Due in the future: fades linearly from 0.65 to zero a month out.
    /// - No due date: a small neglect bonus growing with age since creation,
    ///   so long-forgotten items drift up rather than sitting at the bottom
    ///   forever.
    static func timeUrgency(for item: ReminderItem, now: Date) -> Double {
        guard let due = item.dueDate else {
            guard let created = item.creationDate else { return 0 }
            let age = days(from: created, to: now)
            return 0.15 * Double(min(max(age, 0), 120)) / 120
        }
        let daysUntilDue = days(from: now, to: due)
        if daysUntilDue < 0 {
            return 0.75 + 0.25 * Double(min(-daysUntilDue, 14)) / 14
        }
        if daysUntilDue == 0 {
            return 0.70
        }
        return 0.65 * (1 - Double(min(daysUntilDue, 30)) / 30)
    }

    private static func days(from: Date, to: Date) -> Int {
        let calendar = Calendar.current
        return calendar.dateComponents(
            [.day],
            from: calendar.startOfDay(for: from),
            to: calendar.startOfDay(for: to)
        ).day ?? 0
    }
}
