import XCTest

/// Invariants of the deterministic scoring formula. These encode the
/// failure modes documented against earlier ranking designs — if a future
/// weight tweak reintroduces one, a test names it.
final class UrgencyScorerTests: XCTestCase {
    /// Anchored at noon so the helper's one-hour offset below can never
    /// cross a day boundary — with a raw Date() these tests would fail
    /// when run within an hour of midnight.
    private let now = Calendar.current.startOfDay(for: Date()).addingTimeInterval(12 * 3_600)

    private func item(
        due daysFromNow: Int? = nil,
        created daysAgo: Int = 30,
        priority: Int = 0
    ) -> ReminderItem {
        let day = 86_400.0
        // Offset an hour into the day so calendar-day math is exercised
        // with non-midnight timestamps, like real reminders.
        return ReminderItem(
            id: UUID().uuidString,
            title: "Test",
            notes: nil,
            dueDate: daysFromNow.map { now.addingTimeInterval(Double($0) * day + 3_600) },
            rawPriority: priority,
            listName: "Test",
            creationDate: now.addingTimeInterval(-Double(daysAgo) * day),
            score: nil
        )
    }

    private func score(_ tier: ImportanceTier, _ reminder: ReminderItem, dates: Bool = true) -> Int {
        UrgencyScorer.score(importance: tier, item: reminder, now: now, consideringDueDates: dates)
    }

    // MARK: Date ordering

    func testSameDayOutranksNextDayAtEqualImportance() {
        XCTAssertGreaterThan(score(.normal, item(due: 0)), score(.normal, item(due: 1)))
    }

    func testOverdueOutranksDueToday() {
        XCTAssertGreaterThan(score(.normal, item(due: -1)), score(.normal, item(due: 0)))
    }

    func testCloserDueDatesScoreHigher() {
        let days = [1, 3, 7, 14, 29]
        let scores = days.map { score(.normal, item(due: $0)) }
        XCTAssertEqual(scores, scores.sorted(by: >), "urgency should decrease as due dates recede")
    }

    // MARK: Capped overdue bonus

    func testOverdueBonusCapsAtTwoWeeks() {
        XCTAssertEqual(score(.normal, item(due: -14)), score(.normal, item(due: -60)))
    }

    func testRecentlyOverdueImportantOutranksLongOverdueTrivial() {
        XCTAssertGreaterThan(score(.high, item(due: -2)), score(.low, item(due: -30)))
    }

    // MARK: Importance

    func testHigherImportanceWinsAtEqualDates() {
        let reminder = item(due: 3)
        let ordered: [ImportanceTier] = [.critical, .high, .normal, .low]
        let scores = ordered.map { score($0, reminder) }
        XCTAssertEqual(scores, scores.sorted(by: >))
    }

    func testImportantUpcomingOutranksTrivialOverdue() {
        XCTAssertGreaterThan(score(.critical, item(due: 7)), score(.low, item(due: -30)))
    }

    // MARK: Undated reminders

    func testNeglectGrowsWithAgeAndCaps() {
        let fresh = score(.normal, item(created: 1))
        let old = score(.normal, item(created: 100))
        let ancient = score(.normal, item(created: 400))
        XCTAssertGreaterThan(old, fresh)
        XCTAssertEqual(score(.normal, item(created: 120)), ancient, "neglect bonus should cap at 120 days")
    }

    // MARK: Date-blind mode

    func testDateBlindModeIgnoresDatesEntirely() {
        let overdue = score(.high, item(due: -30), dates: false)
        let undated = score(.high, item(created: 1), dates: false)
        XCTAssertEqual(overdue, undated)
        XCTAssertEqual(overdue, 70, "date-blind high importance should fill the full scale at its weight")
    }

    func testDateBlindTierScale() {
        XCTAssertEqual(score(.critical, item(), dates: false), 100)
        XCTAssertEqual(score(.high, item(), dates: false), 70)
        XCTAssertEqual(score(.normal, item(), dates: false), 40)
        XCTAssertEqual(score(.low, item(), dates: false), 15)
    }

    // MARK: Fallback importance

    func testFallbackImportanceMapsPriorityFlag() {
        XCTAssertEqual(UrgencyScorer.fallbackImportance(for: item(priority: 1)), .high)
        XCTAssertEqual(UrgencyScorer.fallbackImportance(for: item(priority: 5)), .normal)
        XCTAssertEqual(UrgencyScorer.fallbackImportance(for: item(priority: 9)), .low)
        XCTAssertEqual(UrgencyScorer.fallbackImportance(for: item(priority: 0)), .normal,
                       "an unset flag should read as normal — most people never set it")
    }

    // MARK: Bounds

    func testScoresStayWithinBadgeScale() {
        let extremes = [
            score(.critical, item(due: -60)),
            score(.low, item(due: 90)),
            score(.low, item(created: 0)),
            score(.critical, item(), dates: false),
        ]
        for value in extremes {
            XCTAssertTrue((0...100).contains(value), "score \(value) escaped 0-100")
        }
    }
}
