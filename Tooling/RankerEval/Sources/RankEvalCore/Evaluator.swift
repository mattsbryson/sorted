import Foundation

/// Turns exported logs into labeled preference pairs and scores each strategy
/// against them, reusing the exact same `RankingMetrics.pairwiseAgreement` and
/// `PreferenceReconstruction` the in-app Ranker Lab uses. The only work unique
/// to offline evaluation is assembling pairs from files; the scoring is shared.
public enum Evaluator {

    /// A labeled pair carrying the feature snapshots of both items, so a
    /// strategy that scores from features can be applied without a separate
    /// lookup table. `winner` should rank above `loser`.
    public struct Pair: Sendable {
        public let winner: LoggedReminder
        public let loser: LoggedReminder
    }

    /// Per-strategy result over one source of pairs.
    public struct StrategyScore: Sendable {
        public let strategy: String
        public let result: RankingMetrics.PairwiseResult
    }

    // MARK: Building pairs

    /// Explicit pairs straight from Face Off events — the cleanest labels.
    public static func faceOffPairs(_ events: [FaceOffEvent]) -> [Pair] {
        events.map { Pair(winner: $0.winner, loser: $0.loser) }
    }

    /// Implicit pairs reconstructed from preference actions via the shared
    /// `PreferenceReconstruction` rule. The reconstruction works on ids; we
    /// pair each id back to its logged feature snapshot from the event's
    /// context (and the acted item) so strategies can score them.
    public static func preferencePairs(_ events: [PreferenceEvent]) -> [Pair] {
        var pairs: [Pair] = []
        for event in events {
            // id → features, from everything the event carries.
            var byID: [String: LoggedReminder] = [:]
            byID[event.item.id] = event.item.reminder
            for item in event.context { byID[item.id] = item.reminder }

            let action = PreferenceReconstruction.Action(
                action: event.action,
                itemID: event.item.id,
                position: event.item.position,
                context: event.context.map(\.id)
            )
            for labeled in PreferenceReconstruction.pairs(from: action) {
                guard let w = byID[labeled.winner], let l = byID[labeled.loser] else { continue }
                pairs.append(Pair(winner: w, loser: l))
            }
        }
        return pairs
    }

    // MARK: Scoring

    /// Scores one strategy against a set of pairs. Each pair is decided by the
    /// strategy's own scores on the two items' features — the winner should
    /// score strictly higher.
    public static func score(_ strategy: Strategy, over pairs: [Pair]) -> RankingMetrics.PairwiseResult {
        // Give each item a stable synthetic key so equal-id items map to one
        // score; scoring is by features, so we compute directly per pair.
        var result = RankingMetrics.PairwiseResult()
        for pair in pairs {
            let w = strategy.score(pair.winner)
            let l = strategy.score(pair.loser)
            if w > l { result.correct += 1 }
            else if w < l { result.incorrect += 1 }
            else { result.undetermined += 1 }
        }
        return result
    }

    /// Scores every strategy in `strategies` over one pair source.
    public static func scoreAll(_ strategies: [Strategy], over pairs: [Pair]) -> [StrategyScore] {
        strategies.map { StrategyScore(strategy: $0.name, result: score($0, over: pairs)) }
    }
}
