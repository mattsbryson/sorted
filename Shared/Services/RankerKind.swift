import Foundation

/// Which ranking strategy is active. Selectable in Settings so the two
/// experimental rankers can be A/B'd against the shipping Apple prioritizer on
/// real reminders without a rebuild.
///
/// Each experimental case is developed on its own branch and only *does*
/// something there; on a branch where a strategy hasn't landed, `RankerFactory`
/// falls back to the Apple baseline, so every branch compiles and runs. The
/// case list is the shared contract — the branches agree on it and each fills
/// in its own factory arm.
enum RankerKind: String, CaseIterable, Sendable {
    /// Baseline: the shipping on-device FoundationModels prioritizer.
    case apple
    /// Option 1: Core ML learning-to-rank, trained on Face Off / preference
    /// logs. Implemented on branch `ranker-ab/coreml-ltr`.
    case coreML
    /// Option 2: a larger-context on-device LLM (MLX) that ranks a big batch
    /// comparatively in one call. Implemented on branch `ranker-ab/mlx-bigbatch`.
    case mlx

    var displayName: String {
        switch self {
        case .apple: "Apple (baseline)"
        case .coreML: "Core ML LTR"
        case .mlx: "MLX big-batch"
        }
    }

    var detail: String {
        switch self {
        case .apple: "On-device Apple Intelligence: per-item importance + listwise re-rank of the top."
        case .coreML: "Learning-to-rank model trained on your own Face Off and action feedback."
        case .mlx: "Bigger on-device model judging ~40 reminders together in one comparative pass."
        }
    }
}

/// Builds the active ranker. This is the single seam each experimental branch
/// replaces: the `apple` arm always returns the baseline, and each branch swaps
/// its own arm to return its strategy. Kinds whose strategy isn't present on
/// the current branch fall back to the baseline so selecting them never breaks.
enum RankerFactory {
    static func make(_ kind: RankerKind) -> any Ranker {
        switch kind {
        case .apple:
            return AIPrioritizer()
        case .coreML:
            // Core ML LTR ranker (branch `ranker-ab/coreml-ltr`). Falls back to
            // the heuristic ordering internally when its model isn't bundled.
            return CoreMLRanker()
        case .mlx:
            return MLXRanker()
        }
    }
}
