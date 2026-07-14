import XCTest

/// Tests for the Core ML LTR ranker's feature extraction (which must stay in
/// lockstep with Tooling/CoreMLLTR/features.py) and a ranking smoke test.
///
/// These exercise the pure, model-independent parts: the feature vector, the
/// md5 list bucketing, and the end-to-end `rank` pass. When no model is
/// bundled into the test target, `rank` falls back to the heuristic ordering —
/// which is itself a valid, tested behavior (graceful degradation).
final class CoreMLRankerTests: XCTestCase {
    private func item(
        title: String = "Test",
        notes: String? = nil,
        due daysFromNow: Int? = nil,
        list: String = "Test",
        priority: Int = 0
    ) -> ReminderItem {
        let day = 86_400.0
        return ReminderItem(
            id: UUID().uuidString,
            title: title,
            notes: notes,
            dueDate: daysFromNow.map { Date().addingTimeInterval(Double($0) * day) },
            rawPriority: priority,
            listName: list,
            creationDate: Date().addingTimeInterval(-30 * day),
            score: nil
        )
    }

    // MARK: Feature schema

    func testFeatureVectorLength() {
        let feats = CoreMLRanker.features(for: item())
        XCTAssertEqual(feats.count, CoreMLRanker.featureCount)
        XCTAssertEqual(
            CoreMLRanker.featureCount,
            8 + CoreMLRanker.listHashBuckets + TitleEmbedding.dimension
        )
    }

    // MARK: Title embedding (appended tail of the vector)

    func testTitleEmbeddingIsDeterministicAndNormalized() {
        let a = TitleEmbedding.vector(for: "Pay the mortgage")
        let b = TitleEmbedding.vector(for: "Pay the mortgage")
        XCTAssertEqual(a, b, "same text must embed identically")
        XCTAssertEqual(a.count, TitleEmbedding.dimension)
        let norm = a.reduce(0) { $0 + $1 * $1 }.squareRoot()
        // Unit length when embedding assets are available; all-zeros
        // fallback (norm 0) is also valid where they aren't.
        XCTAssertTrue(abs(norm - 1) < 1e-9 || norm == 0)
    }

    func testEmptyTitleEmbedsToZeros() {
        let zeros = TitleEmbedding.vector(for: "   ")
        XCTAssertEqual(zeros, [Double](repeating: 0, count: TitleEmbedding.dimension))
    }

    func testDifferentTitlesEmbedDifferently() {
        let a = TitleEmbedding.vector(for: "Pay the mortgage")
        let b = TitleEmbedding.vector(for: "Buy sponges")
        // Only meaningful where embedding assets exist (norm > 0).
        if a.contains(where: { $0 != 0 }) {
            XCTAssertNotEqual(a, b)
        }
    }

    func testPriorityOneHotIsMutuallyExclusive() {
        for (priority, expectedIndex) in [(1, 0), (3, 0), (5, 1), (7, 2), (0, 3), (99, 3)] {
            let feats = CoreMLRanker.features(for: item(priority: priority))
            let onehot = Array(feats.prefix(4))
            XCTAssertEqual(onehot.reduce(0, +), 1, "priority \(priority) must set exactly one flag")
            XCTAssertEqual(onehot[expectedIndex], 1, "priority \(priority) should set index \(expectedIndex)")
        }
    }

    func testHasNotesAndLengthNormalization() {
        let empty = CoreMLRanker.features(for: item(title: "Hi", notes: "   "))
        XCTAssertEqual(empty[4], 0, "whitespace-only notes should count as no notes")
        XCTAssertEqual(empty[5], Double(2) / 100.0, accuracy: 1e-9, "title_len_norm")
        XCTAssertEqual(empty[6], Double(1) / 20.0, accuracy: 1e-9, "one word")

        let withNotes = CoreMLRanker.features(for: item(title: "a b c", notes: "note"))
        XCTAssertEqual(withNotes[4], 1)
        XCTAssertEqual(withNotes[6], Double(3) / 20.0, accuracy: 1e-9, "three words")
        XCTAssertEqual(withNotes[7], Double(4) / 140.0, accuracy: 1e-9, "notes_len_norm")
    }

    func testTitleAndNotesLengthCap() {
        let long = String(repeating: "x", count: 500)
        let feats = CoreMLRanker.features(for: item(title: long, notes: long))
        XCTAssertEqual(feats[5], 1.0, "title length caps at 100")
        XCTAssertEqual(feats[7], 1.0, "notes length caps at 140")
    }

    // MARK: List bucketing (must match features.py md5 scheme)

    func testListBucketIsStableAndInRange() {
        for name in ["Work", "Personal", "Health", "Groceries", "Someday", ""] {
            let b = CoreMLRanker.listBucket(name)
            XCTAssertTrue((0..<CoreMLRanker.listHashBuckets).contains(b), "bucket for \(name) out of range")
            XCTAssertEqual(b, CoreMLRanker.listBucket(name), "bucketing must be deterministic")
        }
        XCTAssertEqual(CoreMLRanker.listBucket(""), 0, "empty list name -> bucket 0")
    }

    func testListBucketOneHotHasSingleSetBit() {
        let feats = CoreMLRanker.features(for: item(list: "Finance"))
        // Buckets occupy [8, 8+listHashBuckets); the title embedding follows.
        let buckets = Array(feats[8..<(8 + CoreMLRanker.listHashBuckets)])
        XCTAssertEqual(buckets.reduce(0, +), 1, "exactly one list bucket should be set")
    }

    // MARK: Combined scoring

    func testCombinedScoreStaysOnBadgeScale() {
        let now = Date()
        for weight in [0.0, 0.5, 1.0] {
            for due in [-30, 0, 7, nil] {
                let s = CoreMLRanker.combinedScore(
                    importanceWeight: weight,
                    item: item(due: due),
                    now: now,
                    consideringDueDates: true
                )
                XCTAssertTrue((0...100).contains(s), "combined score \(s) escaped 0-100")
            }
        }
    }

    func testDateBlindCombinedScoreIsPureImportance() {
        let s = CoreMLRanker.combinedScore(
            importanceWeight: 0.7,
            item: item(due: -30),
            now: Date(),
            consideringDueDates: false
        )
        XCTAssertEqual(s, 70, "date-blind mode should scale importance weight to 0-100")
    }

    // MARK: Ranking smoke test

    func testRankReturnsAllItemsScoredAndOrdered() async {
        let items = [
            item(title: "Pay tax bill", due: -2, list: "Finance", priority: 1),
            item(title: "Buy milk", due: 20, list: "Groceries", priority: 0),
            item(title: "Submit report", due: 1, list: "Work", priority: 5),
        ]
        let ranked = await CoreMLRanker().rank(items, consideringDueDates: true)

        XCTAssertEqual(ranked.count, items.count, "no items dropped")
        XCTAssertEqual(Set(ranked.map(\.id)), Set(items.map(\.id)), "same items back")
        for r in ranked { XCTAssertNotNil(r.score, "every item scored") }

        let scores = ranked.compactMap(\.score)
        XCTAssertEqual(scores, scores.sorted(by: >), "output must be sorted most-important first")
    }

    func testRankEmptyIsEmpty() async {
        let ranked = await CoreMLRanker().rank([], consideringDueDates: true)
        XCTAssertTrue(ranked.isEmpty)
    }
}
