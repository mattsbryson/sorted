import SwiftUI

struct SettingsView: View {
    @Environment(AppSettings.self) private var settings
    @Environment(\.dismiss) private var dismiss

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
                Text("The Today tab shows up to this many of your most important due-today or overdue reminders.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            VStack(alignment: .leading, spacing: 8) {
                Toggle("Show urgency score", isOn: $settings.showUrgencyScore)
                Text("Displays each reminder's 0-100 urgency score (from Apple Intelligence, or a heuristic estimate) alongside its priority.")
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
        .frame(width: 360, height: 280)
    }
}
