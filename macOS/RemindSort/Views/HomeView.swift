import SwiftUI

struct HomeView: View {
    @Environment(RemindersViewModel.self) private var viewModel
    @State private var showingDeleteConfirmation = false
    @State private var showingSnoozePopover = false
    @State private var snoozeAmount = 1
    @State private var snoozeUnit: SnoozeUnit = .day

    var body: some View {
        NavigationStack {
            content
                .toolbar {
                    ToolbarItem(placement: .automatic) {
                        Button {
                            Task { await viewModel.refresh() }
                        } label: {
                            Image(systemName: "arrow.clockwise")
                        }
                    }
                }
        }
    }

    private var content: some View {
        VStack(spacing: 24) {
            if let note = viewModel.aiNote {
                Label(note, systemImage: "sparkles")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.top, 8)
            }

            Spacer()

            if let reminder = viewModel.homeReminder {
                VStack(spacing: 16) {
                    Text("Most Important")
                        .font(.headline)
                        .foregroundStyle(.secondary)

                    ReminderCard(reminder: reminder)

                    HStack(spacing: 16) {
                        Button {
                            showingSnoozePopover = true
                        } label: {
                            Label("Snooze", systemImage: "zzz")
                        }
                        .buttonStyle(.bordered)
                        .popover(isPresented: $showingSnoozePopover) {
                            SnoozePopover(amount: $snoozeAmount, unit: $snoozeUnit) {
                                Task { await viewModel.snooze(reminder, amount: snoozeAmount, unit: snoozeUnit) }
                                showingSnoozePopover = false
                            }
                        }

                        Button {
                            Task { await viewModel.complete(reminder) }
                        } label: {
                            Label("Complete", systemImage: "checkmark.circle.fill")
                        }
                        .buttonStyle(.borderedProminent)

                        Button {
                            viewModel.skipHome()
                        } label: {
                            Label("Skip", systemImage: "arrow.uturn.forward.circle")
                        }
                        .buttonStyle(.bordered)

                        Button(role: .destructive) {
                            showingDeleteConfirmation = true
                        } label: {
                            Label("Delete", systemImage: "trash")
                        }
                        .buttonStyle(.bordered)
                    }
                    .controlSize(.large)
                }
                .padding(32)
                .frame(maxWidth: 420)
                .confirmationDialog(
                    "Delete “\(reminder.title)”?",
                    isPresented: $showingDeleteConfirmation,
                    titleVisibility: .visible
                ) {
                    Button("Delete", role: .destructive) {
                        Task { await viewModel.delete(reminder) }
                    }
                    Button("Cancel", role: .cancel) {}
                }
            } else {
                ContentUnavailableView(
                    "All Clear",
                    systemImage: "checkmark.circle",
                    description: Text("You have no pending reminders.")
                )
            }

            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// macOS has no wheel-style picker (SwiftUI's .wheel picker style is
// unavailable on macOS), so amount/unit selection uses a stepper + segmented
// picker instead as the platform-native equivalent.
private struct SnoozePopover: View {
    @Binding var amount: Int
    @Binding var unit: SnoozeUnit
    var onConfirm: () -> Void

    var body: some View {
        VStack(spacing: 16) {
            Text("Snooze")
                .font(.headline)

            Stepper("\(amount) \(unit.pluralized(for: amount))", value: $amount, in: 1...30)

            Picker("Unit", selection: $unit) {
                ForEach(SnoozeUnit.allCases) { unit in
                    Text(unit.pluralized(for: amount)).tag(unit)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            Button("Snooze", action: onConfirm)
                .buttonStyle(.borderedProminent)
                .frame(maxWidth: .infinity)
        }
        .padding()
        .frame(width: 260)
    }
}

private struct ReminderCard: View {
    let reminder: ReminderItem

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(reminder.listName)
                    .font(.caption)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(.tertiary, in: Capsule())
                Spacer()
                PriorityBadge(level: reminder.priorityLevel)
            }

            Text(reminder.title)
                .font(.title2.weight(.semibold))

            if let notes = reminder.notes, !notes.isEmpty {
                Text(notes)
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
            }

            if let due = reminder.dueDate {
                Label(due.formatted(date: .abbreviated, time: .shortened), systemImage: "calendar")
                    .font(.subheadline)
                    .foregroundStyle(reminder.isOverdue ? .red : .secondary)
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(.separator))
    }
}
