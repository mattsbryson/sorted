import XCTest

/// Unit tests for the shared ranking-comparison math (`RankingMetrics`) and the
/// implicit-preference reconstruction (`PreferenceReconstruction`). These are
/// the one implementation used by both the in-app Ranker Lab and the offline
/// `RankerEval` CLI, so their correctness underpins every comparison either
/// surface makes.
final class RankingMetricsTests: XCTestCase {

    // MARK: Kendall tau

    func testTauIdenticalOrderingsIsOne() {
        let order = ["a", "b", "c", "d"]
        XCTAssertEqual(RankingMetrics.kendallTau(order, order)!, 1.0, accuracy: 1e-9)
    }

    func testTauReversedOrderingsIsMinusOne() {
        let a = ["a", "b", "c", "d"]
        let b = ["d", "c", "b", "a"]
        XCTAssertEqual(RankingMetrics.kendallTau(a, b)!, -1.0, accuracy: 1e-9)
    }

    func testTauSingleSwapIsBetweenZeroAndOne() {
        // One adjacent swap out of six pairs: 5 concordant, 1 discordant → 4/6.
        let a = ["a", "b", "c", "d"]
        let b = ["b", "a", "c", "d"]
        XCTAssertEqual(RankingMetrics.kendallTau(a, b)!, 4.0 / 6.0, accuracy: 1e-9)
    }

    func testTauOnlyOverSharedItems() {
        // "e"/"z" appear in only one side and must be ignored, leaving the
        // shared triple a,b,c identical → tau 1.
        let a = ["a", "b", "c", "e"]
        let b = ["z", "a", "b", "c"]
        XCTAssertEqual(RankingMetrics.kendallTau(a, b)!, 1.0, accuracy: 1e-9)
    }

    func testTauNilWhenFewerThanTwoShared() {
        XCTAssertNil(RankingMetrics.kendallTau(["a"], ["a"]))
        XCTAssertNil(RankingMetrics.kendallTau(["a", "b"], ["c", "d"]))
    }

    // MARK: Deltas and movement

    func testRankDeltasSignConvention() {
        let a = ["a", "b", "c"]
        let b = ["b", "c", "a"]
        let deltas = RankingMetrics.rankDeltas(a, b)
        XCTAssertEqual(deltas["a"], 2, "a fell from 0 to 2")
        XCTAssertEqual(deltas["b"], -1, "b rose from 1 to 0")
        XCTAssertEqual(deltas["c"], -1, "c rose from 2 to 1")
    }

    func testFractionMovedThreshold() {
        let a = ["a", "b", "c", "d"]
        let b = ["b", "a", "c", "d"]
        // a and b each moved by 1; c, d unchanged.
        XCTAssertEqual(RankingMetrics.fractionMoved(a, b, byMoreThan: 0)!, 0.5, accuracy: 1e-9)
        XCTAssertEqual(RankingMetrics.fractionMoved(a, b, byMoreThan: 1)!, 0.0, accuracy: 1e-9)
    }

    // MARK: Pairwise agreement — ordering

    func testPairwiseAgreementOnOrdering() {
        let order = ["a", "b", "c"]
        let pairs = [
            RankingMetrics.LabeledPair(winner: "a", loser: "c"), // correct
            RankingMetrics.LabeledPair(winner: "c", loser: "a"), // incorrect
            RankingMetrics.LabeledPair(winner: "b", loser: "z"), // undetermined (z missing)
        ]
        let r = RankingMetrics.pairwiseAgreement(ordering: order, pairs: pairs)
        XCTAssertEqual(r.correct, 1)
        XCTAssertEqual(r.incorrect, 1)
        XCTAssertEqual(r.undetermined, 1)
        XCTAssertEqual(r.accuracy!, 0.5, accuracy: 1e-9)
    }

    func testPairwiseAccuracyNilWhenNothingDecidable() {
        let r = RankingMetrics.pairwiseAgreement(
            ordering: ["a"],
            pairs: [RankingMetrics.LabeledPair(winner: "x", loser: "y")]
        )
        XCTAssertEqual(r.undetermined, 1)
        XCTAssertNil(r.accuracy)
    }

    // MARK: Pairwise agreement — score function

    func testPairwiseAgreementOnScores() {
        let scores = ["a": 3.0, "b": 2.0, "c": 2.0]
        let pairs = [
            RankingMetrics.LabeledPair(winner: "a", loser: "b"), // correct 3>2
            RankingMetrics.LabeledPair(winner: "b", loser: "c"), // tie → undetermined
            RankingMetrics.LabeledPair(winner: "c", loser: "a"), // incorrect 2<3
        ]
        let r = RankingMetrics.pairwiseAgreement(score: { scores[$0] }, pairs: pairs)
        XCTAssertEqual(r.correct, 1)
        XCTAssertEqual(r.incorrect, 1)
        XCTAssertEqual(r.undetermined, 1)
    }

    // MARK: NDCG

    func testNdcgPerfectOrderingIsOne() {
        let order = ["a", "b", "c"]
        let rel = ["a": 3.0, "b": 2.0, "c": 1.0]
        XCTAssertEqual(RankingMetrics.ndcg(ordering: order, relevance: rel)!, 1.0, accuracy: 1e-9)
    }

    func testNdcgWorseOrderingScoresLower() {
        let good = RankingMetrics.ndcg(ordering: ["a", "b", "c"], relevance: ["a": 3, "b": 2, "c": 1])!
        let bad = RankingMetrics.ndcg(ordering: ["c", "b", "a"], relevance: ["a": 3, "b": 2, "c": 1])!
        XCTAssertGreaterThan(good, bad)
        XCTAssertEqual(good, 1.0, accuracy: 1e-9)
    }

    func testNdcgNilWithoutPositiveRelevance() {
        XCTAssertNil(RankingMetrics.ndcg(ordering: ["a", "b"], relevance: [:]))
    }

    // MARK: Preference reconstruction

    private func action(
        _ verb: String,
        _ id: String,
        at position: Int,
        context: [String]
    ) -> PreferenceReconstruction.Action<String> {
        .init(action: verb, itemID: id, position: position, context: context)
    }

    func testCompleteBeatsEverythingBelow() {
        let pairs = PreferenceReconstruction.pairs(
            from: action("complete", "b", at: 1, context: ["a", "b", "c", "d"])
        )
        // b (position 1) beats c and d, not a.
        XCTAssertEqual(Set(pairs), [
            .init(winner: "b", loser: "c"),
            .init(winner: "b", loser: "d"),
        ])
    }

    func testSkipLosesToEverythingBelow() {
        let pairs = PreferenceReconstruction.pairs(
            from: action("skip_today", "a", at: 0, context: ["a", "b", "c"])
        )
        // The user moved past a to consider b and c, so both outrank a.
        XCTAssertEqual(Set(pairs), [
            .init(winner: "b", loser: "a"),
            .init(winner: "c", loser: "a"),
        ])
    }

    func testSnoozeTreatedLikeSkip() {
        let pairs = PreferenceReconstruction.pairs(
            from: action("snooze", "a", at: 0, context: ["a", "b"])
        )
        XCTAssertEqual(pairs, [.init(winner: "b", loser: "a")])
    }

    func testDeleteLosesToAllOthersBothSides() {
        let pairs = PreferenceReconstruction.pairs(
            from: action("delete", "b", at: 1, context: ["a", "b", "c"])
        )
        // Everything remaining outranks the deleted item, above and below.
        XCTAssertEqual(Set(pairs), [
            .init(winner: "a", loser: "b"),
            .init(winner: "c", loser: "b"),
        ])
    }

    func testCompleteAtBottomYieldsNoPairs() {
        let pairs = PreferenceReconstruction.pairs(
            from: action("complete", "c", at: 2, context: ["a", "b", "c"])
        )
        XCTAssertTrue(pairs.isEmpty, "nothing below the last item to compare against")
    }

    func testUnknownActionYieldsNoPairs() {
        XCTAssertTrue(PreferenceReconstruction.pairs(
            from: action("wat", "a", at: 0, context: ["a", "b"])
        ).isEmpty)
    }

    func testItemMissingFromContextYieldsNoPairs() {
        XCTAssertTrue(PreferenceReconstruction.pairs(
            from: action("complete", "z", at: 0, context: ["a", "b"])
        ).isEmpty)
    }
}
