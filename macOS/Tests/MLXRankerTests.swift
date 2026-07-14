import XCTest

/// Pure-function tests for the MLX big-batch ranker: prompt construction,
/// free-text output parsing, and the omission/duplicate rebuild. The model
/// itself can't run in CI (needs an Apple-Silicon device and a runtime
/// download), so these exercise everything around it — the parts that must be
/// correct for the ranking to be trustworthy.
final class MLXRankerTests: XCTestCase {
    private let now = Calendar.current.startOfDay(for: Date()).addingTimeInterval(12 * 3_600)

    private func item(
        id: String = UUID().uuidString,
        title: String = "Task",
        notes: String? = nil,
        due daysFromNow: Int? = nil,
        created daysAgo: Int? = 30,
        list: String = "Inbox",
        priority: Int = 0
    ) -> ReminderItem {
        let day = 86_400.0
        return ReminderItem(
            id: id,
            title: title,
            notes: notes,
            dueDate: daysFromNow.map { now.addingTimeInterval(Double($0) * day + 3_600) },
            rawPriority: priority,
            listName: list,
            creationDate: daysAgo.map { now.addingTimeInterval(-Double($0) * day) },
            score: nil
        )
    }

    // MARK: buildPrompt

    func testBuildPromptTokenizesEveryItemAndMapsToIDs() {
        let items = [item(id: "a"), item(id: "b"), item(id: "c")]
        let (instructions, prompt, tokenToID) = MLXRanker.buildPrompt(
            for: items, includeDates: false, now: now)

        XCTAssertEqual(tokenToID["R0"], "a")
        XCTAssertEqual(tokenToID["R1"], "b")
        XCTAssertEqual(tokenToID["R2"], "c")
        XCTAssertEqual(tokenToID.count, 3)
        XCTAssertTrue(prompt.contains("[R0]"))
        XCTAssertTrue(prompt.contains("[R2]"))
        // The instruction must ask for space-separated tokens, each once.
        XCTAssertTrue(instructions.lowercased().contains("token"))
        XCTAssertTrue(instructions.contains("exactly once"))
    }

    func testBuildPromptOmitsDatesWhenDisabled() {
        let items = [item(id: "a", due: -3)]
        let (_, prompt, _) = MLXRanker.buildPrompt(for: items, includeDates: false, now: now)
        XCTAssertFalse(prompt.contains("due="))
        XCTAssertFalse(prompt.contains("created="))
    }

    func testBuildPromptIncludesAppComputedRelativeDatesWhenEnabled() {
        let items = [item(id: "a", due: -3, created: 10)]
        let (_, prompt, _) = MLXRanker.buildPrompt(for: items, includeDates: true, now: now)
        // App pre-computes offsets; the model never does date math.
        XCTAssertTrue(prompt.contains("due=overdue by 3 days"))
        XCTAssertTrue(prompt.contains("created=10 days ago"))
    }

    func testBuildPromptTruncatesLongNotesTo140Chars() {
        let long = String(repeating: "x", count: 200)
        let items = [item(id: "a", notes: long)]
        let (_, prompt, _) = MLXRanker.buildPrompt(for: items, includeDates: false, now: now)
        XCTAssertTrue(prompt.contains("…"))
        XCTAssertFalse(prompt.contains(String(repeating: "x", count: 200)))
    }

    // MARK: parseOrder

    func testParseOrderExtractsTokensInEmittedOrder() {
        let map = ["R0": "a", "R1": "b", "R2": "c"]
        let ids = MLXRanker.parseOrder("R2 R0 R1", tokenToID: map)
        XCTAssertEqual(ids, ["c", "a", "b"])
    }

    func testParseOrderToleratesCommentaryAndPunctuation() {
        let map = ["R0": "a", "R1": "b", "R2": "c"]
        let ids = MLXRanker.parseOrder(
            "Sure! The order is: R1, then R2, and finally R0.", tokenToID: map)
        XCTAssertEqual(ids, ["b", "c", "a"])
    }

    func testParseOrderDropsDuplicatesKeepingFirst() {
        let map = ["R0": "a", "R1": "b"]
        let ids = MLXRanker.parseOrder("R0 R1 R0 R1", tokenToID: map)
        XCTAssertEqual(ids, ["a", "b"])
    }

    func testParseOrderIgnoresUnknownTokens() {
        let map = ["R0": "a", "R1": "b"]
        // R9 isn't in the batch; "Rank" must not be mistaken for a token.
        let ids = MLXRanker.parseOrder("Rank: R9 R1 R0", tokenToID: map)
        XCTAssertEqual(ids, ["b", "a"])
    }

    func testParseOrderMultiDigitTokens() {
        var map: [String: String] = [:]
        for i in 0..<40 { map["R\(i)"] = "id\(i)" }
        let ids = MLXRanker.parseOrder("R39 R1 R12", tokenToID: map)
        XCTAssertEqual(ids, ["id39", "id1", "id12"])
    }

    func testParseOrderEmptyOnNoTokens() {
        XCTAssertTrue(MLXRanker.parseOrder("no tokens here", tokenToID: ["R0": "a"]).isEmpty)
    }

    // MARK: reorder (omission/duplicate fallback)

    func testReorderAppendsOmittedItemsInOriginalOrder() {
        let batch = [item(id: "a"), item(id: "b"), item(id: "c")]
        // Model only emitted b; a and c must keep their relative order at the end.
        let result = MLXRanker.reorder(batch, byIDs: ["b"])
        XCTAssertEqual(result.map(\.id), ["b", "a", "c"])
    }

    func testReorderFullOrdering() {
        let batch = [item(id: "a"), item(id: "b"), item(id: "c")]
        let result = MLXRanker.reorder(batch, byIDs: ["c", "a", "b"])
        XCTAssertEqual(result.map(\.id), ["c", "a", "b"])
    }

    func testReorderIgnoresDuplicateAndUnknownIDs() {
        let batch = [item(id: "a"), item(id: "b")]
        let result = MLXRanker.reorder(batch, byIDs: ["b", "b", "zzz", "a"])
        XCTAssertEqual(result.map(\.id), ["b", "a"])
    }

    // MARK: deterministicOrder (pre-sort / fallback)

    func testDeterministicOrderPutsOverdueAboveFuture() {
        let overdue = item(id: "overdue", due: -2)
        let future = item(id: "future", due: 10)
        let sorted = MLXRanker.deterministicOrder(
            [future, overdue], consideringDueDates: true, now: now)
        XCTAssertEqual(sorted.first?.id, "overdue")
    }

    func testDeterministicOrderAssignsScores() {
        let sorted = MLXRanker.deterministicOrder(
            [item(id: "a", due: 0)], consideringDueDates: true, now: now)
        XCTAssertNotNil(sorted.first?.score)
    }

    func testBatchSizeIsBig() {
        // The whole premise of this arm: a large comparative batch.
        XCTAssertGreaterThanOrEqual(MLXRanker.batchSize, 40)
    }
}
