import XCTest
@testable import RankEvalCore

/// Tests for the CLI-side pieces: log decoding, pair assembly from both log
/// types, and end-to-end scoring. The shared metric math and reconstruction
/// rule are exercised by the app's `SortedTests`; here we verify the harness
/// wires them to logged data correctly.
final class RankEvalCoreTests: XCTestCase {

    // MARK: JSONL decoding

    func testJSONLDecodesAndSkipsBadLines() {
        let data = Data("""
        {"ts":"t","winner":{"id":"a","title":"A","notes":null,"list":"L","dueInDays":1,"createdDaysAgo":2,"priority":0,"score":50},"loser":{"id":"b","title":"B","notes":null,"list":"L","dueInDays":3,"createdDaysAgo":4,"priority":0,"score":40}}

        not json at all
        {"ts":"t2","winner":{"id":"c","title":"C","notes":null,"list":"L","dueInDays":0,"createdDaysAgo":1,"priority":1,"score":80},"loser":{"id":"d","title":"D","notes":null,"list":"L","dueInDays":10,"createdDaysAgo":1,"priority":0,"score":30}}
        """.utf8)
        let events = JSONL.decode(FaceOffEvent.self, from: data)
        XCTAssertEqual(events.count, 2, "blank and malformed lines are skipped, valid ones kept")
        XCTAssertEqual(events[0].winner.id, "a")
        XCTAssertEqual(events[1].loser.id, "d")
    }

    // MARK: Pair assembly

    func testFaceOffPairsPreserveWinnerLoser() {
        let e = FaceOffEvent(
            ts: "t",
            winner: LoggedReminder(id: "w", title: "", notes: nil, list: "", dueInDays: nil, createdDaysAgo: nil, priority: 0, score: nil),
            loser: LoggedReminder(id: "l", title: "", notes: nil, list: "", dueInDays: nil, createdDaysAgo: nil, priority: 0, score: nil)
        )
        let pairs = Evaluator.faceOffPairs([e])
        XCTAssertEqual(pairs.count, 1)
        XCTAssertEqual(pairs[0].winner.id, "w")
        XCTAssertEqual(pairs[0].loser.id, "l")
    }

    func testPreferencePairsReconstructComplete() throws {
        // "complete" at position 0 → the completed item beats the two below it.
        let json = """
        {"ts":"t","action":"complete","snoozeDays":null,"item":{"position":0,"id":"top","title":"","notes":null,"list":"","dueInDays":0,"createdDaysAgo":0,"priority":0,"score":90},"context":[{"position":0,"id":"top","title":"","notes":null,"list":"","dueInDays":0,"createdDaysAgo":0,"priority":0,"score":90},{"position":1,"id":"mid","title":"","notes":null,"list":"","dueInDays":5,"createdDaysAgo":0,"priority":0,"score":50},{"position":2,"id":"bot","title":"","notes":null,"list":"","dueInDays":null,"createdDaysAgo":0,"priority":0,"score":20}]}
        """
        let events = JSONL.decode(PreferenceEvent.self, from: Data(json.utf8))
        XCTAssertEqual(events.count, 1)
        let pairs = Evaluator.preferencePairs(events)
        XCTAssertEqual(pairs.count, 2)
        XCTAssertTrue(pairs.allSatisfy { $0.winner.id == "top" })
        XCTAssertEqual(Set(pairs.map { $0.loser.id }), ["mid", "bot"])
    }

    func testPreferencePairsCarryFeatures() {
        let json = """
        {"ts":"t","action":"complete","snoozeDays":null,"item":{"position":0,"id":"top","title":"T","notes":null,"list":"","dueInDays":0,"createdDaysAgo":0,"priority":1,"score":90},"context":[{"position":0,"id":"top","title":"T","notes":null,"list":"","dueInDays":0,"createdDaysAgo":0,"priority":1,"score":90},{"position":1,"id":"bot","title":"B","notes":null,"list":"","dueInDays":null,"createdDaysAgo":0,"priority":0,"score":20}]}
        """
        let pairs = Evaluator.preferencePairs(JSONL.decode(PreferenceEvent.self, from: Data(json.utf8)))
        // Features must be attached so a strategy can score without a lookup.
        XCTAssertEqual(pairs.first?.winner.priority, 1)
        XCTAssertEqual(pairs.first?.loser.score, 20)
    }

    // MARK: Scoring

    func testScoreCountsCorrectWrongUndetermined() {
        func rem(_ id: String, score: Int) -> LoggedReminder {
            LoggedReminder(id: id, title: "", notes: nil, list: "", dueInDays: nil, createdDaysAgo: nil, priority: 0, score: score)
        }
        // Rank purely by logged score for a deterministic expectation.
        let pairs = [
            Evaluator.Pair(winner: rem("a", score: 90), loser: rem("b", score: 10)), // correct
            Evaluator.Pair(winner: rem("c", score: 10), loser: rem("d", score: 90)), // wrong
            Evaluator.Pair(winner: rem("e", score: 50), loser: rem("f", score: 50)), // tie
        ]
        let result = Evaluator.score(Strategies.loggedScore, over: pairs)
        XCTAssertEqual(result.correct, 1)
        XCTAssertEqual(result.incorrect, 1)
        XCTAssertEqual(result.undetermined, 1)
        XCTAssertEqual(result.accuracy!, 0.5, accuracy: 1e-9)
    }

    func testHeuristicBaselinePrefersOverdueImportantOverTrivial() {
        let important = LoggedReminder(id: "i", title: "", notes: nil, list: "", dueInDays: -1, createdDaysAgo: 5, priority: 1, score: nil)
        let trivial = LoggedReminder(id: "t", title: "", notes: nil, list: "", dueInDays: nil, createdDaysAgo: 5, priority: 0, score: nil)
        XCTAssertGreaterThan(
            Strategies.heuristicBaseline.score(important),
            Strategies.heuristicBaseline.score(trivial)
        )
    }

    // MARK: Sample data smoke test

    func testSampleDataIsEvaluable() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // RankEvalCoreTests
            .deletingLastPathComponent()  // Tests
            .deletingLastPathComponent()  // package root
        let faceOffs = try JSONL.decode(FaceOffEvent.self, fromFile: root.appendingPathComponent("SampleData/faceoffs.jsonl"))
        let prefs = try JSONL.decode(PreferenceEvent.self, fromFile: root.appendingPathComponent("SampleData/preferences.jsonl"))
        XCTAssertFalse(faceOffs.isEmpty, "sample face-off log should decode")
        XCTAssertFalse(prefs.isEmpty, "sample preference log should decode")

        let foPairs = Evaluator.faceOffPairs(faceOffs)
        let prefPairs = Evaluator.preferencePairs(prefs)
        XCTAssertFalse(foPairs.isEmpty)
        XCTAssertFalse(prefPairs.isEmpty)

        // Every strategy should produce a defined accuracy on the sample.
        for score in Evaluator.scoreAll(Strategies.all, over: foPairs) {
            XCTAssertNotNil(score.result.accuracy, "\(score.strategy) had no decidable face-off pairs")
        }
    }
}
