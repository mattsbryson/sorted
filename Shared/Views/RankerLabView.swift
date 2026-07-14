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

    /// b_position - a_position for each id, from the left ordering to the
    /// right one: negative means the item is higher (nearer the top) on the
    /// right. Keyed to whichever side is being rendered.
    private var deltas: [String: Int] {
        RankingMetrics.rankDeltas(left.map(\.id), right.map(\.id))
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
                // One row per rank position, pairing A's item at that rank
                // with B's item at the same rank so the eye reads each slot
                // across; the delta badge on the B side shows how far that
                // item moved relative to A.
                ForEach(0..<max(left.count, right.count), id: \.self) { index in
                    HStack(alignment: .top, spacing: 8) {
                        cell(item: left[safe: index], rank: index, delta: nil)
                        cell(item: right[safe: index], rank: index, delta: right[safe: index].flatMap { deltas[$0.id] })
                    }
                    .padding(.vertical, 6)
                    .padding(.horizontal)
                    if index < max(left.count, right.count) - 1 { Divider() }
                }
            }
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Text("A · \(leftKind.displayName)")
                .frame(maxWidth: .infinity, alignment: .leading)
            Text("B · \(rightKind.displayName)")
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .font(.caption.weight(.semibold))
        .foregroundStyle(.secondary)
        .padding(.horizontal)
        .padding(.vertical, 6)
    }

    private func cell(item: ReminderItem?, rank: Int, delta: Int?) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Text("\(rank + 1)")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.tertiary)
                .frame(minWidth: 18, alignment: .trailing)
            if let item {
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.title)
                        .font(.subheadline)
                        .lineLimit(2)
                    Text(item.listName)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 4)
                if let delta { deltaBadge(delta) }
            } else {
                Text("—")
                    .foregroundStyle(.tertiary)
                Spacer(minLength: 0)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Signed rank change badge: green ▲ moved up (toward the top) on side B,
    /// red ▼ moved down, grey dot unchanged. The number is how many slots.
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

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
