import Foundation
import RankEvalCore

// Offline evaluation harness for the Sorted ranking strategies.
//
// Usage:
//   swift run RankerEval [faceoffs.jsonl] [preferences.jsonl]
//
// With no arguments it evaluates the bundled synthetic sample logs so a fresh
// `swift run` prints meaningful output immediately. Point it at real exported
// logs (Settings ▸ Export Log… / Export Face-Off Log…) to evaluate on your own
// data. Either file may be omitted or missing — the harness reports on whatever
// it finds.

let arguments = Array(CommandLine.arguments.dropFirst())

/// Resolve the sample-data directory relative to this source file, so the
/// default `swift run` works from anywhere in the package.
let sampleDir = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent()   // Sources/RankerEval
    .deletingLastPathComponent()   // Sources
    .deletingLastPathComponent()   // package root
    .appendingPathComponent("SampleData")

let faceOffURL: URL = arguments.count >= 1
    ? URL(fileURLWithPath: arguments[0])
    : sampleDir.appendingPathComponent("faceoffs.jsonl")
let preferencesURL: URL = arguments.count >= 2
    ? URL(fileURLWithPath: arguments[1])
    : sampleDir.appendingPathComponent("preferences.jsonl")

let usingSample = arguments.isEmpty

func load<T: Decodable>(_ type: T.Type, _ url: URL) -> [T] {
    (try? JSONL.decode(type, fromFile: url)) ?? []
}

let faceOffs = load(FaceOffEvent.self, faceOffURL)
let preferences = load(PreferenceEvent.self, preferencesURL)

let faceOffPairs = Evaluator.faceOffPairs(faceOffs)
let preferencePairs = Evaluator.preferencePairs(preferences)

// MARK: Report

func hr() { print(String(repeating: "─", count: 68)) }

func padLeft(_ s: String, _ width: Int) -> String {
    s.count >= width ? s : String(repeating: " ", count: width - s.count) + s
}
func padRight(_ s: String, _ width: Int) -> String {
    s.count >= width ? s : s + String(repeating: " ", count: width - s.count)
}

func row(_ name: String, _ accuracy: String, _ correct: String, _ wrong: String, _ undet: String) -> String {
    "  " + padRight(name, 20) + " " + padLeft(accuracy, 9) + " "
        + padLeft(correct, 8) + " " + padLeft(wrong, 8) + " " + padLeft(undet, 8)
}

func table(title: String, source: URL, events: Int, pairs: [Evaluator.Pair]) {
    hr()
    print(title)
    print("  source: \(source.lastPathComponent)   events: \(events)   pairs: \(pairs.count)")
    hr()
    guard !pairs.isEmpty else {
        print("  (no pairs — nothing to score)\n")
        return
    }
    print(row("strategy", "accuracy", "correct", "wrong", "undet."))
    for score in Evaluator.scoreAll(Strategies.all, over: pairs) {
        let r = score.result
        let acc = r.accuracy.map { String(format: "%.1f%%", $0 * 100) } ?? "n/a"
        print(row(score.strategy, acc, "\(r.correct)", "\(r.incorrect)", "\(r.undetermined)"))
    }
    print("")
}

print("")
print("Sorted — Ranker Evaluation")
if usingSample {
    print("(no arguments given — evaluating bundled synthetic sample data)")
}
print("")

print("Strategies under test:")
for s in Strategies.all {
    print("  • \(s.name): \(s.detail)")
}
print("")

table(
    title: "EXPLICIT — Face Off pairwise judgments",
    source: faceOffURL,
    events: faceOffs.count,
    pairs: faceOffPairs
)

table(
    title: "IMPLICIT — reconstructed from preference actions",
    source: preferencesURL,
    events: preferences.count,
    pairs: preferencePairs
)

hr()
print("""
  accuracy = correct / (correct + wrong), over decidable pairs.
  \"undet.\" = ties or a missing item — excluded from accuracy.
  Higher accuracy = the strategy agrees more with the recorded judgments.
""")
hr()
print("")

if faceOffPairs.isEmpty && preferencePairs.isEmpty {
    print("No pairs found in either log. Pass paths to exported .jsonl files:")
    print("  swift run RankerEval /path/faceoffs.jsonl /path/preferences.jsonl")
    exit(0)
}
