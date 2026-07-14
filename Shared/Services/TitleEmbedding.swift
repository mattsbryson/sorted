import Foundation
import NaturalLanguage

/// A compact semantic vector for a reminder's title — the feature that lets
/// the learned ranker tell "pay the mortgage" from "buy sponges" when list
/// and priority don't differ (which, measured on real face-off data, is
/// about half of all judged pairs).
///
/// Pipeline: Apple's on-device sentence embedding (`NLEmbedding`, ~512 dims)
/// → a fixed, deterministic random projection down to `dimension` dims
/// (Johnson–Lindenstrauss style; a linear model with a few hundred training
/// pairs would drown in raw 512) → L2 normalization.
///
/// **Swift/Python parity is by construction, not by porting**: the training
/// pipeline (`Tooling/CoreMLLTR`) never reimplements this — it shells out to
/// `Tooling/EmbedTool`, a tiny CLI compiled from this same file. Any change
/// here changes both sides together; retrain and re-bundle after edits.
///
/// If the sentence-embedding assets are unavailable (or the text is empty),
/// the vector is all zeros: the embedding contributes nothing and the
/// model's other features (priority, list, lengths) carry the score alone.
/// Note the underlying NLEmbedding assets ship with the OS and can differ
/// across OS versions — vectors are stable on one machine, approximate
/// across them; retraining occasionally re-anchors this.
enum TitleEmbedding {
    /// Output dimensionality after projection.
    static let dimension = 32

    /// Fixed seed for the projection matrix — part of the feature schema.
    /// Changing it invalidates any trained model.
    private static let projectionSeed: UInt64 = 0x536F72746564_01 // "Sorted",v1

    /// `nonisolated(unsafe)`: immutable after load and used read-only, same
    /// justification as `CoreMLRanker.model` (NLEmbedding isn't `Sendable`).
    nonisolated(unsafe) private static let sentenceEmbedding: NLEmbedding? =
        NLEmbedding.sentenceEmbedding(for: .english)

    /// `dimension` floats, L2-normalized; all zeros when no embedding is
    /// available for the text.
    static func vector(for text: String) -> [Double] {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let embedding = sentenceEmbedding,
              let raw = embedding.vector(for: trimmed)
        else { return [Double](repeating: 0, count: dimension) }
        return normalize(project(raw))
    }

    /// Sign-flip random projection: out[j] = Σ_i in[i] * s(i,j) / √dimension,
    /// with s(i,j) ∈ {+1, −1} drawn from a SplitMix64 stream seeded once —
    /// deterministic for a given input dimensionality, no stored matrix.
    private static func project(_ input: [Double]) -> [Double] {
        var output = [Double](repeating: 0, count: dimension)
        var rng = SplitMix64(state: projectionSeed &+ UInt64(input.count))
        let scale = 1.0 / Double(dimension).squareRoot()
        for value in input {
            for j in 0..<dimension {
                let sign: Double = (rng.next() & 1) == 0 ? 1 : -1
                output[j] += value * sign * scale
            }
        }
        return output
    }

    private static func normalize(_ vector: [Double]) -> [Double] {
        let norm = vector.reduce(0) { $0 + $1 * $1 }.squareRoot()
        guard norm > 0 else { return vector }
        return vector.map { $0 / norm }
    }

    /// Deterministic 64-bit PRNG (SplitMix64) — same sequence on every
    /// platform and run, which is the whole point.
    private struct SplitMix64 {
        var state: UInt64
        mutating func next() -> UInt64 {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return z ^ (z >> 31)
        }
    }
}
