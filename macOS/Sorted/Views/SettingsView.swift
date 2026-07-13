import SwiftUI

struct SettingsView: View {
    @Environment(AppSettings.self) private var settings
    @Environment(RemindersViewModel.self) private var viewModel
    @Environment(\.dismiss) private var dismiss

    @State private var showingLogExporter = false
    @State private var showingFaceOffExporter = false

    var body: some View {
        @Bindable var settings = settings

        VStack(alignment: .leading, spacing: 20) {
            Text("Settings")
                .font(.title2.weight(.semibold))

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

            Spacer()

            HStack {
                Spacer()
                Button("Done") { dismiss() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 360, height: 580)
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
        // Re-rank right away so the new order greets the user on close. No
        // model calls happen here — importance stays cached; only the
        // deterministic score composition changes.
        .onChange(of: settings.considerDueDates) {
            Task { await viewModel.refresh() }
        }
    }
}
