import SwiftUI

struct SettingsView: View {
    @Environment(AppSettings.self) private var settings
    @Environment(RemindersViewModel.self) private var viewModel
    @Environment(\.dismiss) private var dismiss

    @State private var showingLogExporter = false
    @State private var showingFaceOffExporter = false

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
                } header: {
                    Text("Experimental")
                } footer: {
                    Text(settings.rankerKind.detail)
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
                } footer: {
                    Text("Adds a tab where you pick the more important of two reminders. Each pick is saved on this device as a direct comparison — the cleanest training data for a personalized ranking model.")
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
            // Re-rank right away so the new order greets the user on close.
            // No model calls happen here — importance stays cached; only the
            // deterministic score composition changes.
            .onChange(of: settings.considerDueDates) {
                Task { await viewModel.refresh() }
            }
            // Switching strategy re-ranks from scratch with the new model.
            .onChange(of: settings.rankerKind) {
                Task { await viewModel.refresh() }
            }
            // Hiding/showing a list changes which reminders exist for
            // ranking, so re-run the pass to reflect it immediately.
            .onChange(of: settings.ignoredLists) {
                Task { await viewModel.refresh() }
            }
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}
