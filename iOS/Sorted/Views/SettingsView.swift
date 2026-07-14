import SwiftUI

struct SettingsView: View {
    @Environment(AppSettings.self) private var settings
    @Environment(RemindersViewModel.self) private var viewModel
    @Environment(\.dismiss) private var dismiss

    @State private var showingLogExporter = false
    @State private var showingFaceOffExporter = false
    @State private var showingFaceOffImporter = false
    @State private var rankingInputsAtOpen: RankingInputs?

    var body: some View {
        @Bindable var settings = settings

        NavigationStack {
            Form {
                Section {
                    Stepper(
                        "Reminders shown in Today: \(settings.todayLimit)",
                        value: $settings.todayLimit,
                        in: AppSettings.todayLimitRange
                    )
                } footer: {
                    Text("The Today tab shows up to this many of your most important reminders overall, regardless of when they're due.")
                }

                Section {
                    Picker("Ranking model", selection: $settings.rankerKind) {
                        ForEach(RankerKind.allCases, id: \.self) { kind in
                            Text(kind.displayName).tag(kind)
                        }
                    }
                    // Which LLM the MLX arm runs — only meaningful when that
                    // arm can actually be exercised (selected as the active
                    // strategy, or comparable via the Ranker Lab), so it's
                    // hidden otherwise rather than reading as a second,
                    // parallel model choice.
                    if settings.rankerKind == .mlx || settings.rankerLabEnabled {
                        Picker("MLX model", selection: $settings.mlxModel) {
                            ForEach(MLXModelChoice.allCases, id: \.self) { choice in
                                Text(choice.displayName).tag(choice)
                            }
                        }
                    }
                } header: {
                    Text("Experimental")
                } footer: {
                    if settings.rankerKind == .mlx || settings.rankerLabEnabled {
                        Text(settings.rankerKind.detail + " MLX model: " + settings.mlxModel.detail)
                    } else {
                        Text(settings.rankerKind.detail)
                    }
                }

                Section {
                    Toggle("Show urgency score", isOn: $settings.showUrgencyScore)
                } footer: {
                    Text("Displays each reminder's 0-100 urgency score (from Apple Intelligence, or a heuristic estimate) alongside its priority.")
                }

                Section {
                    Toggle("Consider due dates in ranking", isOn: $settings.considerDueDates)
                } footer: {
                    Text("When off, reminders are ranked purely by how important each task is, ignoring due dates and overdue status.")
                }

                Section {
                    Toggle("Log ranking feedback", isOn: $settings.preferenceLogging)
                    Button("Export Log…") {
                        showingLogExporter = true
                    }
                    .disabled(!PreferenceLog.hasLoggedData)
                } footer: {
                    Text("Records skips, completes, snoozes, and deletes (with the ranking you saw) on this device only — future training data for a personalized ranking model.")
                }

                Section {
                    Toggle("Show Face Off tab", isOn: $settings.faceOffEnabled)
                    Button("Export Face-Off Log…") {
                        showingFaceOffExporter = true
                    }
                    .disabled(!FaceOffLog.hasLoggedData)
                    Button("Import Face-Off Log…") {
                        showingFaceOffImporter = true
                    }
                } footer: {
                    Text("Adds a tab where you pick the more important of two reminders. Each pick is saved on this device as a direct comparison — the cleanest training data for a personalized ranking model. Import merges a log exported from another device.")
                }

                Section {
                    Toggle("Show Ranker Lab tab", isOn: $settings.rankerLabEnabled)
                } footer: {
                    Text("Adds a read-only tab that runs your reminders through two ranking strategies side by side, highlighting which items moved and by how much, with a rank-agreement score. Nothing is changed or logged.")
                }

                if !viewModel.availableLists.isEmpty {
                    Section {
                        ForEach(viewModel.availableLists, id: \.self) { list in
                            Toggle(list, isOn: Binding(
                                get: { !settings.isListIgnored(list) },
                                set: { settings.setList(list, ignored: !$0) }
                            ))
                        }
                    } header: {
                        Text("Lists")
                    } footer: {
                        Text("Turn a list off to hide its reminders everywhere in the app.")
                    }
                }
            }
            .navigationTitle("Settings")
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
            // Merges a log exported from another device (e.g. the iPhone's
            // face-offs) into this device's log, so prompt personalization
            // and future training see the combined history.
            .fileImporter(
                isPresented: $showingFaceOffImporter,
                allowedContentTypes: [TrainingLog.exportType, .plainText]
            ) { result in
                guard case .success(let url) = result else { return }
                let accessing = url.startAccessingSecurityScopedResource()
                defer { if accessing { url.stopAccessingSecurityScopedResource() } }
                if let data = try? Data(contentsOf: url) {
                    FaceOffLog.importData(data)
                }
            }
            // Re-rank once, after Settings closes — never on each toggle.
            // refresh() flips loadState to .loading, which swaps the tabs
            // (and this sheet along with them) for the loading screen; doing
            // that mid-edit dismisses Settings on every change, so you can't
            // turn off several lists in a row. Snapshot the ranking-affecting
            // inputs on open and, if they differ on close, re-rank so the new
            // order greets the user.
            .onAppear {
                rankingInputsAtOpen = RankingInputs(
                    considerDueDates: settings.considerDueDates,
                    ignoredLists: settings.ignoredLists,
                    rankerKind: settings.rankerKind,
                    mlxModel: settings.mlxModel
                )
            }
            .onDisappear {
                let current = RankingInputs(
                    considerDueDates: settings.considerDueDates,
                    ignoredLists: settings.ignoredLists,
                    rankerKind: settings.rankerKind,
                    mlxModel: settings.mlxModel
                )
                if let initial = rankingInputsAtOpen, current != initial {
                    Task { await viewModel.refresh() }
                }
            }
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
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
    var mlxModel: MLXModelChoice
}
