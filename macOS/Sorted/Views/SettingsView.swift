import SwiftUI

struct SettingsView: View {
    @Environment(AppSettings.self) private var settings
    @Environment(RemindersViewModel.self) private var viewModel
    @Environment(\.dismiss) private var dismiss

    @State private var showingLogExporter = false
    @State private var showingFaceOffExporter = false
    @State private var rankingInputsAtOpen: RankingInputs?

    var body: some View {
        @Bindable var settings = settings

        VStack(alignment: .leading, spacing: 16) {
            Text("Settings")
                .font(.title2.weight(.semibold))

            ScrollView {
             VStack(alignment: .leading, spacing: 20) {
            VStack(alignment: .leading, spacing: 8) {
                Stepper(
                    "Reminders shown in Today: \(settings.todayLimit)",
                    value: $settings.todayLimit,
                    in: AppSettings.todayLimitRange
                )
                Text("The Today tab shows up to this many of your most important reminders overall, regardless of when they're due.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("Experimental")
                    .font(.subheadline.weight(.medium))
                Picker("Ranking model", selection: $settings.rankerKind) {
                    ForEach(RankerKind.allCases, id: \.self) { kind in
                        Text(kind.displayName).tag(kind)
                    }
                }
                Text(settings.rankerKind.detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            VStack(alignment: .leading, spacing: 8) {
                Toggle("Show urgency score", isOn: $settings.showUrgencyScore)
                Text("Displays each reminder's 0-100 urgency score (from Apple Intelligence, or a heuristic estimate) alongside its priority.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            VStack(alignment: .leading, spacing: 8) {
                Toggle("Consider due dates in ranking", isOn: $settings.considerDueDates)
                Text("When off, reminders are ranked purely by how important each task is, ignoring due dates and overdue status.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            VStack(alignment: .leading, spacing: 8) {
                Toggle("Log ranking feedback", isOn: $settings.preferenceLogging)
                HStack {
                    Button("Export Log…") {
                        showingLogExporter = true
                    }
                    .disabled(!PreferenceLog.hasLoggedData)
                }
                Text("Records skips, completes, snoozes, and deletes (with the ranking you saw) on this device only — future training data for a personalized ranking model.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            VStack(alignment: .leading, spacing: 8) {
                Toggle("Show Face Off tab", isOn: $settings.faceOffEnabled)
                HStack {
                    Button("Export Face-Off Log…") {
                        showingFaceOffExporter = true
                    }
                    .disabled(!FaceOffLog.hasLoggedData)
                }
                Text("Adds a tab where you pick the more important of two reminders. Each pick is saved on this device as a direct comparison — the cleanest training data for a personalized ranking model.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            VStack(alignment: .leading, spacing: 8) {
                Toggle("Show Ranker Lab tab", isOn: $settings.rankerLabEnabled)
                Text("Adds a read-only tab that runs your reminders through two ranking strategies side by side, highlighting which items moved and by how much, with a rank-agreement score. Nothing is changed or logged.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if !viewModel.availableLists.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Lists")
                        .font(.subheadline.weight(.medium))
                    ForEach(viewModel.availableLists, id: \.self) { list in
                        Toggle(list, isOn: Binding(
                            get: { !settings.isListIgnored(list) },
                            set: { settings.setList(list, ignored: !$0) }
                        ))
                    }
                    Text("Turn a list off to hide its reminders everywhere in the app.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
             }
            }

            HStack {
                Spacer()
                Button("Done") { dismiss() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 360, height: 600)
        .fileExporter(
            isPresented: $showingLogExporter,
            document: PreferenceLog.ExportDocument(data: PreferenceLog.exportData()),
            contentType: PreferenceLog.exportType,
            defaultFilename: "Sorted-preferences"
        ) { _ in }
        .fileExporter(
            isPresented: $showingFaceOffExporter,
            document: TrainingLog.ExportDocument(data: FaceOffLog.exportData()),
            contentType: TrainingLog.exportType,
            defaultFilename: "Sorted-faceoffs"
        ) { _ in }
        // Re-rank once, after Settings closes — never on each toggle.
        // refresh() flips loadState to .loading, which swaps the tabs (and
        // this sheet along with them) for the loading screen; doing that
        // mid-edit dismisses Settings on every change, so you can't turn off
        // several lists in a row. Snapshot the ranking-affecting inputs on
        // open and, if they differ on close, re-rank so the new order greets
        // the user.
        .onAppear {
            rankingInputsAtOpen = RankingInputs(
                considerDueDates: settings.considerDueDates,
                ignoredLists: settings.ignoredLists,
                rankerKind: settings.rankerKind
            )
        }
        .onDisappear {
            let current = RankingInputs(
                considerDueDates: settings.considerDueDates,
                ignoredLists: settings.ignoredLists,
                rankerKind: settings.rankerKind
            )
            if let initial = rankingInputsAtOpen, current != initial {
                Task { await viewModel.refresh() }
            }
        }
    }
}

/// Snapshot of the settings that affect ranking output, captured when
/// Settings opens so it can re-rank exactly once on close, and only when one
/// of these actually changed.
private struct RankingInputs: Equatable {
    var considerDueDates: Bool
    var ignoredLists: Set<String>
    var rankerKind: RankerKind
}
