import SwiftUI

struct SettingsView: View {
    @Environment(AppSettings.self) private var settings
    @Environment(RemindersViewModel.self) private var viewModel
    @Environment(\.dismiss) private var dismiss

    @State private var showingLogExporter = false

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
            }
            .navigationTitle("Settings")
            .fileExporter(
                isPresented: $showingLogExporter,
                document: PreferenceLog.ExportDocument(data: PreferenceLog.exportData()),
                contentType: PreferenceLog.exportType,
                defaultFilename: "RemindSort-preferences"
            ) { _ in }
            // Re-rank right away so the new order greets the user on close.
            // No model calls happen here — importance stays cached; only the
            // deterministic score composition changes.
            .onChange(of: settings.considerDueDates) {
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
