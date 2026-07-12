import SwiftUI

struct SettingsView: View {
    @Environment(AppSettings.self) private var settings
    @Environment(\.dismiss) private var dismiss

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
                    Text("The Today tab shows up to this many of your most important due-today or overdue reminders.")
                }

                Section {
                    Toggle("Show urgency score", isOn: $settings.showUrgencyScore)
                } footer: {
                    Text("Displays each reminder's 0-100 urgency score (from Apple Intelligence, or a heuristic estimate) alongside its priority.")
                }
            }
            .navigationTitle("Settings")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}
