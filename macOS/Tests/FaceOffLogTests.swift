import XCTest

/// Tests for the pure de-duplication core of Face Off log importing.
/// Exports are cumulative (each contains the device's whole history), so
/// merging must be idempotent: the same event — timestamp + pair — must
/// survive exactly once no matter how many overlapping exports are imported,
/// while genuine re-judgments (different timestamps) are kept.
final class FaceOffLogTests: XCTestCase {
    private func line(ts: String, winner: String, loser: String) -> String {
        """
        {"ts":"\(ts)","winner":{"id":"\(winner)","title":"W","list":"L","priority":0},\
        "loser":{"id":"\(loser)","title":"X","list":"L","priority":0}}
        """
    }

    private func blob(_ lines: [String]) -> Data {
        Data((lines.joined(separator: "\n") + "\n").utf8)
    }

    func testKeepsDistinctEventsAndDropsExactDuplicates() {
        let a = line(ts: "2026-07-14T18:00:00Z", winner: "a", loser: "b")
        let b = line(ts: "2026-07-14T18:00:01Z", winner: "c", loser: "d")
        var seen = Set<String>()
        let result = FaceOffLog.dedupedLines(blob([a, b, a]), seenKeys: &seen)
        XCTAssertEqual(result.count, 2)
    }

    func testCumulativeReExportAddsNothing() {
        let first = [
            line(ts: "2026-07-14T18:00:00Z", winner: "a", loser: "b"),
            line(ts: "2026-07-14T18:00:01Z", winner: "c", loser: "d"),
        ]
        // The second export contains everything from the first plus one new.
        let second = first + [line(ts: "2026-07-14T18:00:02Z", winner: "e", loser: "f")]

        var seen = Set<String>()
        XCTAssertEqual(FaceOffLog.dedupedLines(blob(first), seenKeys: &seen).count, 2)
        XCTAssertEqual(FaceOffLog.dedupedLines(blob(second), seenKeys: &seen).count, 1)
        // Importing the older export again after the newer one adds nothing.
        XCTAssertEqual(FaceOffLog.dedupedLines(blob(first), seenKeys: &seen).count, 0)
    }

    func testReJudgmentOfSamePairAtDifferentTimeIsKept() {
        let earlier = line(ts: "2026-07-14T18:00:00Z", winner: "a", loser: "b")
        let later = line(ts: "2026-07-14T19:00:00Z", winner: "b", loser: "a")
        var seen = Set<String>()
        XCTAssertEqual(FaceOffLog.dedupedLines(blob([earlier, later]), seenKeys: &seen).count, 2)
    }

    func testUndecodableLinesAreDropped() {
        let good = line(ts: "2026-07-14T18:00:00Z", winner: "a", loser: "b")
        var seen = Set<String>()
        let result = FaceOffLog.dedupedLines(blob(["not json", good, "{\"ts\":\"x\"}"]), seenKeys: &seen)
        XCTAssertEqual(result.count, 1)
    }
}
