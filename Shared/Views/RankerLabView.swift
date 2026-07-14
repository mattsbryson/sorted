import SwiftUI

/// The Ranker Lab tab (shown when enabled in Settings): runs the current live
/// reminder set through two selectable strategies and shows their orderings
/// side by side, with each item's rank change between the two highlighted and a
/// Kendall-tau rank-agreement number for the whole pair. Strictly read-only —
/// it re-ranks a *copy* of the reminders and never mutates anything, logs
/// nothing, and completes/skips nothing.
///
/// Ranker-agnostic by construction: it drives everything through `RankerKind`
/// and the `Ranker` protocol, so once the Core ML and MLX arms land on their
/// branches and merge, the picker offers all three and the diff just works with
/// no change here. On this branch the experimental kinds fall back to the Apple
/// baseline (see `RankerFactory`), so selecting two of them shows tau = 1.
struct RankerLabView: View {
    @Environment(RemindersViewModel.self) private var viewModel

    @State private var leftKind: RankerKind = .apple
    @State private var rightKind: RankerKind = .coreML

    @State private var left: [ReminderItem] = []
    @State private var right: [ReminderItem] = []
    @State private var isRunning = false

    /// One row per reminder: the item with its position in each strategy's
    /// ordering. Ordered by each reminder's **best** rank across the two
    /// strategies (ties by A's rank), so whatever either model puts on top is
    /// at the top of the page.
    private struct ComparisonRow: Identifiable {
        let item: ReminderItem
        let aRank: Int?
        let bRank: Int?
        var id: String { item.id }
        var bestRank: Int { min(aRank ?? .max, bRank ?? .max) }
    }

    private var rows: [ComparisonRow] {
        let aIndex = Dictionary(uniqueKeysWithValues: left.enumerated().map { ($1.id, $0) })
        let bIndex = Dictionary(uniqueKeysWithValues: right.enumerated().map { ($1.id, $0) })
        // Both strategies rank the same set, but tolerate divergence: any item
        // present on either side gets a row, with — for a missing rank.
        var seen = Set<String>()
        var all: [ComparisonRow] = []
        for item in left + right where seen.insert(item.id).inserted {
            all.append(ComparisonRow(item: item, aRank: aIndex[item.id], bRank: bIndex[item.id]))
        }
        return all.sorted { lhs, rhs in
            if lhs.bestRank != rhs.bestRank { return lhs.bestRank < rhs.bestRank }
            return (lhs.aRank ?? .max) < (rhs.aRank ?? .max)
        }
    }

    private var tau: Double? {
        RankingMetrics.kendallTau(left.map(\.id), right.map(\.id))
    }

    private var fractionMoved: Double? {
        RankingMetrics.fractionMoved(left.map(\.id), right.map(\.id), byMoreThan: 0)
    }

    var body: some View {
        NavigationStack {
            Group {
                if viewModel.rankedReminders.count < 2 {
                    ContentUnavailableView(
                        "Not Enough Reminders",
                        systemImage: "chart.bar.doc.horizontal",
                        description: Text("Add at least two reminders to compare ranking strategies.")
                    )
                } else {
                    content
                }
            }
            .navigationTitle("Ranker Lab")
        }
        .task(id: taskKey) { await run() }
    }

    /// Re-run whenever either chosen strategy or the underlying set changes.
    /// The set is fingerprinted by hashing every id in order (stable within a
    /// session, which is all `.task(id:)` needs) — count + first id missed
    /// changes deeper in the list.
    private var taskKey: String {
        var hasher = Hasher()
        for item in viewModel.rankedReminders {
            hasher.combine(item.id)
        }
        return "\(leftKind.rawValue)|\(rightKind.rawValue)|\(hasher.finalize())"
    }

    private var content: some View {
        VStack(spacing: 0) {
            pickers
            agreementBar
            Divider()
            if isRunning && (left.isEmpty || right.isEmpty) {
                Spacer()
                ProgressView("Ranking…")
                Spacer()
            } else {
                // Re-runs keep the previous comparison visible but dimmed
                // with a spinner, so a slow model pass reads as "updating"
                // rather than "the picker did nothing".
                comparisonList
                    .opacity(isRunning ? 0.4 : 1)
                    .overlay {
                        if isRunning { ProgressView("Ranking…") }
                    }
            }
        }
    }

    private var pickers: some View {
        HStack(spacing: 12) {
            strategyPicker("A", selection: $leftKind)
            Image(systemName: "arrow.left.arrow.right")
                .foregroundStyle(.secondary)
                .font(.caption)
            strategyPicker("B", selection: $rightKind)
        }
        .padding(.horizontal)
        .padding(.top, 8)
    }

    private func strategyPicker(_ label: String, selection: Binding<RankerKind>) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
            Picker(label, selection: selection) {
                ForEach(RankerKind.allCases, id: \.self) { kind in
                    Text(kind.displayName).tag(kind)
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var agreementBar: some View {
        HStack {
            metric(
                "Kendall τ",
                tau.map { String(format: "%+.2f", $0) } ?? "n/a",
                help: "Rank agreement between A and B: +1 identical, −1 reversed."
            )
            Spacer()
            metric(
                "Moved",
                fractionMoved.map { "\(Int(($0 * 100).rounded()))%" } ?? "n/a",
                help: "Share of reminders that changed position at all between A and B."
            )
            Spacer()
            metric(
                "Reminders",
                "\(viewModel.rankedReminders.count)",
                help: "Number of reminders ranked by both strategies."
            )
        }
        .padding(.horizontal)
        .padding(.vertical, 10)
    }

    private func metric(_ title: String, _ value: String, help: String) -> some View {
        VStack(spacing: 1) {
            Text(value)
                .font(.headline.monospacedDigit())
            Text(title)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .help(help)
    }

    private var comparisonList: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                header
                Divider()
                // One row per reminder, ordered by its best rank across the
                // two strategies — the top of the page is whatever either
                // model considers most important. Each row carries the item's
                // rank under A and under B, plus the movement between them.
                let rows = self.rows
                ForEach(rows) { row in
                    rowView(row)
                        .padding(.vertical, 6)
                        .padding(.horizontal)
                    if row.id != rows.last?.id { Divider() }
                }
            }
        }
    }

    private var header: some View {
        HStack(spacing: 6) {
            Text("A · \(leftKind.displayName)")
            Text("vs")
                .foregroundStyle(.tertiary)
            Text("B · \(rightKind.displayName)")
            Spacer()
        }
        .font(.caption.weight(.semibold))
        .foregroundStyle(.secondary)
        .padding(.horizontal)
        .padding(.vertical, 6)
    }

    private func rowView(_ row: ComparisonRow) -> some View {
        HStack(alignment: .center, spacing: 10) {
            rankChip("A", row.aRank)
            rankChip("B", row.bRank)
            VStack(alignment: .leading, spacing: 2) {
                Text(row.item.title)
                    .font(.subheadline)
                    .lineLimit(2)
                Text(row.item.listName)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 4)
            if let a = row.aRank, let b = row.bRank {
                deltaBadge(b - a)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// The item's 1-based position under one strategy ("—" if it's somehow
    /// absent from that side's ordering).
    private func rankChip(_ label: String, _ rank: Int?) -> some View {
        VStack(spacing: 0) {
            Text(label)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
            Text(rank.map { "\($0 + 1)" } ?? "—")
                .font(.callout.monospacedDigit().weight(.semibold))
        }
        .frame(minWidth: 26)
    }

    /// Signed rank-change badge (B relative to A): green ▲ B ranks it higher
    /// (nearer the top), red ▼ B ranks it lower, grey = same position. The
    /// number is how many slots it moved.
    private func deltaBadge(_ delta: Int) -> some View {
        Group {
            if delta == 0 {
                Label("0", systemImage: "equal")
                    .foregroundStyle(.secondary)
            } else if delta < 0 {
                Label("\(abs(delta))", systemImage: "arrow.up")
                    .foregroundStyle(.green)
            } else {
                Label("\(delta)", systemImage: "arrow.down")
                    .foregroundStyle(.red)
            }
        }
        .font(.caption2.monospacedDigit().weight(.semibold))
        .labelStyle(.titleAndIcon)
    }

    private func run() async {
        isRunning = true
        // Changing a picker (or the reminder set) changes taskKey, which
        // cancels this task and starts a fresh one — but the awaited model
        // calls run to completion regardless. Without the cancellation guard,
        // a superseded run finishing late overwrote the newer run's results
        // (pickers showing one pair, lists showing another), and a rank
        // cancelled mid-model-call falls back to its deterministic order,
        // which would get written over the display. Only the current run may
        // publish; a cancelled run also leaves `isRunning` to its successor.
        defer { if !Task.isCancelled { isRunning = false } }
        // Sequential, not concurrent: the on-device model serializes calls
        // anyway, and a fresh instance per rank keeps them independent.
        let a = await viewModel.rankForLab(leftKind)
        let b = await viewModel.rankForLab(rightKind)
        guard !Task.isCancelled else { return }
        left = a
        right = b
    }
}
