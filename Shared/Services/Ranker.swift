import Foundation

/// A pluggable ranking strategy.
///
/// The app has exactly one ranking entry point — `rank(_:consideringDueDates:)`
/// — and everything from the shipping Apple on-device prioritizer to the
/// experimental Core ML learning-to-rank and MLX big-batch rankers conforms to
/// this. That single seam is what lets the strategies be swapped at runtime
/// (see `RankerKind`/`RankerFactory`) and compared head-to-head on real data
/// (see the Ranker Lab tooling) without touching call sites.
///
/// Implementations must treat `rank` as pure with respect to `items`: the same
/// input should yield a comparable ordering every call, with no reliance on
/// external mutable state, so two strategies fed the identical reminder set can
/// be diffed meaningfully. Any loaded model or cache a strategy needs should
/// live in shared/static storage (like `ImportanceCache`/`TopOrderCache`), not
/// in per-call instance state, because the factory may build a fresh instance
/// per rank.
protocol Ranker: Sendable {
    /// Whether this strategy can actually run right now. Drives the AI note in
    /// the UI and lets the factory fall back to a baseline when a strategy's
    /// model isn't present or the platform doesn't support it.
    var availability: AIAvailability { get }

    /// Returns all items ranked most- to least-important. Callers show a
    /// loading state for the duration — this is the whole ranking pass.
    func rank(_ items: [ReminderItem], consideringDueDates: Bool) async -> [ReminderItem]
}

extension AIPrioritizer: Ranker {
    /// The shipping strategy's availability is the Apple Intelligence model's
    /// availability, exposed per-instance so it reaches through the protocol.
    var availability: AIAvailability { Self.availability }
}
