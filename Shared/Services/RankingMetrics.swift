import Foundation

/// Pure, dependency-free ranking-comparison math shared by the in-app Ranker
/// Lab and the offline `RankerEval` CLI, so there is exactly one tested
/// implementation of each metric rather than two that can drift.
///
/// Everything here operates on abstract identifiers (`Hashable`) and labeled
/// pairs, never on `ReminderItem` or any ranker, so it stays ranker-agnostic:
/// feed it two orderings (or a set of preference pairs plus one ordering) and
/// it reports how much they agree. That is the whole contract the Core ML and
/// MLX arms build against when their branches merge — no metric changes needed.
public enum RankingMetrics {

    // MARK: Rank agreement between two orderings

    /// Kendall's tau-b rank correlation between two orderings of the *same*
    /// set of items, in `-1...1`: `1` identical, `-1` reversed, `0` unrelated.
    ///
    /// Tau-b (not tau-a) so ties are handled gracefully — the app can legitimately
    /// leave two items in the same relative slot, and a strict tau-a would punish
    /// that as if it were a disagreement. Items present in only one ordering are
    /// ignored (the correlation is defined only over the shared set).
    ///
    /// Returns `nil` when fewer than two items are shared (a correlation over
    /// 0 or 1 items is undefined), so callers can show "n/a" rather than a
    /// misleading `0`.
    public static func kendallTau<ID: Hashable>(_ a: [ID], _ b: [ID]) -> Double? {
        let rankA = ranks(of: a)
        let rankB = ranks(of: b)
        let shared = a.filter { rankB[$0] != nil }
        let n = shared.count
        guard n >= 2 else { return nil }

        var concordant = 0
        var discordant = 0
        var tiesA = 0
        var tiesB = 0
        for i in 0..<n {
            for j in (i + 1)..<n {
                guard
                    let ai = rankA[shared[i]], let aj = rankA[shared[j]],
                    let bi = rankB[shared[i]], let bj = rankB[shared[j]]
                else { continue }
                let da = ai - aj
                let db = bi - bj
                if da == 0 && db == 0 {
                    // Tied in both — contributes to neither denominator term.
                    continue
                } else if da == 0 {
                    tiesA += 1
                } else if db == 0 {
                    tiesB += 1
                } else if (da < 0) == (db < 0) {
                    concordant += 1
                } else {
                    discordant += 1
                }
            }
        }
        let denom = sqrt(Double(concordant + discordant + tiesA))
            * sqrt(Double(concordant + discordant + tiesB))
        guard denom > 0 else { return nil }
        return Double(concordant - discordant) / denom
    }

    /// Fraction of items whose absolute rank position changed by *more than*
    /// `threshold` slots between the two orderings, over the shared set — a
    /// plain-language companion to tau ("30% of items moved by 3+ spots").
    /// Returns `nil` if nothing is shared.
    public static func fractionMoved<ID: Hashable>(_ a: [ID], _ b: [ID], byMoreThan threshold: Int = 0) -> Double? {
        let rankB = ranks(of: b)
        let deltas = rankDeltas(a, b)
        let shared = a.filter { rankB[$0] != nil }
        guard !shared.isEmpty else { return nil }
        let moved = shared.filter { abs(deltas[$0] ?? 0) > threshold }.count
        return Double(moved) / Double(shared.count)
    }

    /// Per-item signed rank change from ordering `a` to ordering `b`
    /// (`b_position - a_position`): negative means the item moved *up* toward
    /// the top in `b`, positive means it fell. Only items present in both
    /// orderings get an entry. This is what the Lab's delta column renders.
    public static func rankDeltas<ID: Hashable>(_ a: [ID], _ b: [ID]) -> [ID: Int] {
        let rankA = ranks(of: a)
        let rankB = ranks(of: b)
        var result: [ID: Int] = [:]
        for (id, ra) in rankA {
            if let rb = rankB[id] { result[id] = rb - ra }
        }
        return result
    }

    // MARK: Pairwise agreement against labeled preferences

    /// One judged preference: `winner` should rank above `loser`. This is the
    /// unit both Face Off (explicit) and reconstructed preference actions
    /// (implicit) reduce to, so a single accuracy routine scores either source.
    public struct LabeledPair<ID: Hashable & Sendable>: Hashable, Sendable {
        public let winner: ID
        public let loser: ID
        public init(winner: ID, loser: ID) {
            self.winner = winner
            self.loser = loser
        }
    }

    /// Result of scoring a ranker against a set of labeled pairs.
    public struct PairwiseResult: Sendable {
        /// Pairs the ranker ordered the same way the label says (winner above loser).
        public var correct = 0
        /// Pairs the ranker ordered the opposite way.
        public var incorrect = 0
        /// Pairs that couldn't be scored — an item wasn't in the ranking, or the
        /// ranker tied them (neither strictly above the other).
        public var undetermined = 0

        public init() {}

        /// Pairs that produced a strict decision (correct + incorrect).
        public var scored: Int { correct + incorrect }
        public var total: Int { correct + incorrect + undetermined }

        /// Fraction of *decidable* pairs ordered correctly, in `0...1`. `nil`
        /// when nothing was decidable, so callers show "n/a" not a false `0`.
        public var accuracy: Double? {
            scored > 0 ? Double(correct) / Double(scored) : nil
        }
    }

    /// Scores an ordering against labeled preference pairs: for each pair, does
    /// the ranking place `winner` strictly above `loser`? Ties and pairs with a
    /// missing item are counted as `undetermined` rather than silently
    /// dropped, so the caller can see coverage, not just accuracy.
    ///
    /// This is the core offline metric — "of the comparisons the user actually
    /// made, what fraction does this strategy get right" — and it's identical
    /// whether the pairs came from Face Off or from reconstructed actions.
    public static func pairwiseAgreement<ID: Hashable>(
        ordering: [ID],
        pairs: [LabeledPair<ID>]
    ) -> PairwiseResult {
        let rank = ranks(of: ordering)
        var result = PairwiseResult()
        for pair in pairs {
            guard let w = rank[pair.winner], let l = rank[pair.loser] else {
                result.undetermined += 1
                continue
            }
            if w < l {
                result.correct += 1
            } else if w > l {
                result.incorrect += 1
            } else {
                result.undetermined += 1
            }
        }
        return result
    }

    /// Scores labeled pairs directly against a scoring function (item → score,
    /// higher = more important) without materializing an ordering first — used
    /// by the CLI, where each strategy is a score function over logged items
    /// and there is no single global ranking to diff against. Equal scores are
    /// `undetermined` (a genuine tie, not a win either way).
    public static func pairwiseAgreement<ID: Hashable>(
        score: (ID) -> Double?,
        pairs: [LabeledPair<ID>]
    ) -> PairwiseResult {
        var result = PairwiseResult()
        for pair in pairs {
            guard let w = score(pair.winner), let l = score(pair.loser) else {
                result.undetermined += 1
                continue
            }
            if w > l {
                result.correct += 1
            } else if w < l {
                result.incorrect += 1
            } else {
                result.undetermined += 1
            }
        }
        return result
    }

    // MARK: NDCG

    /// Normalized Discounted Cumulative Gain of an `ordering` given a relevance
    /// (gain) for each item, in `0...1`: `1` when the ordering is sorted by
    /// descending relevance, lower as high-relevance items sink. A cheap,
    /// standard "is the good stuff near the top" score for when a graded
    /// relevance signal is available (e.g. derived from user actions). Items
    /// with no supplied relevance contribute `0` gain. Returns `nil` if the
    /// ideal DCG is `0` (no positive relevance anywhere), where NDCG is undefined.
    public static func ndcg<ID: Hashable>(ordering: [ID], relevance: [ID: Double]) -> Double? {
        func dcg(_ order: [ID]) -> Double {
            order.enumerated().reduce(0) { sum, pair in
                let gain = relevance[pair.element] ?? 0
                // Standard log2(rank+1) discount; rank is 1-based.
                return sum + gain / (log2(Double(pair.offset) + 2))
            }
        }
        let ideal = ordering.sorted { (relevance[$0] ?? 0) > (relevance[$1] ?? 0) }
        let idcg = dcg(ideal)
        guard idcg > 0 else { return nil }
        return dcg(ordering) / idcg
    }

    // MARK: Helpers

    /// Maps each id to its 0-based position. On duplicate ids (shouldn't happen
    /// for reminder ids, but be defensive) the first occurrence wins.
    private static func ranks<ID: Hashable>(of ordering: [ID]) -> [ID: Int] {
        var result: [ID: Int] = [:]
        for (index, id) in ordering.enumerated() where result[id] == nil {
            result[id] = index
        }
        return result
    }
}
