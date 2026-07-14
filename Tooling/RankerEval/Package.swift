// swift-tools-version: 6.0
import PackageDescription

// Self-contained offline evaluation harness for the Sorted ranking strategies.
//
// RankEvalCore holds the pure logic — the shared ranking metrics and implicit-
// preference reconstruction (symlinked in from ../../Shared so there's one copy
// on disk, not a drifting fork), the logged-data decoders, and the ranking
// strategies to score. RankerEval is the thin CLI that wires them to a file and
// prints a report. Splitting them lets the core be unit-tested without a process.
let package = Package(
    name: "RankerEval",
    targets: [
        .target(name: "RankEvalCore"),
        .executableTarget(
            name: "RankerEval",
            dependencies: ["RankEvalCore"]
        ),
        .testTarget(
            name: "RankEvalCoreTests",
            dependencies: ["RankEvalCore"]
        ),
    ]
)
