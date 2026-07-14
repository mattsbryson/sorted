// swift-tools-version:6.0
import PackageDescription

// Tiny CLI wrapping Shared/Services/TitleEmbedding.swift (symlinked into
// Sources/embedtool) so the Python training pipeline computes title
// embeddings with the *identical* Swift code the app runs — parity by
// construction. Reads a JSON array of strings on stdin, writes a JSON array
// of float arrays on stdout. See Tooling/CoreMLLTR/README.md.
let package = Package(
    name: "EmbedTool",
    platforms: [.macOS(.v15)],
    targets: [
        .executableTarget(name: "embedtool", path: "Sources/embedtool")
    ]
)
