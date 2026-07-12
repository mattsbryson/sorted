import SwiftUI

struct HomeView: View {
    @Environment(RemindersViewModel.self) private var viewModel
    @State private var showingDeleteConfirmation = false
    @State private var showingSnoozeSheet = false
    @State private var snoozeAmount = 1
    @State private var snoozeUnit: SnoozeUnit = .day

    var body: some View {
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

                    VStack(spacing: 12) {
                        HStack(spacing: 12) {
                            Button {
                                showingSnoozeSheet = true
                            } label: {
                                Label("Snooze", systemImage: "zzz")
                                    .frame(maxWidth: .infinity)
                            }
                            .buttonStyle(.bordered)

                            Button {
                                Task { await viewModel.complete(reminder) }
                            } label: {
                                Label("Complete", systemImage: "checkmark.circle.fill")
                                    .frame(maxWidth: .infinity)
                            }
                            .buttonStyle(.borderedProminent)
                        }
                        .controlSize(.large)

                        HStack(spacing: 12) {
                            Button {
                                viewModel.skipHome()
                            } label: {
                                Label("Skip", systemImage: "arrow.uturn.forward.circle")
                                    .frame(maxWidth: .infinity)
                            }
                            .buttonStyle(.bordered)

                            Button(role: .destructive) {
                                showingDeleteConfirmation = true
                            } label: {
                                Label("Delete", systemImage: "trash")
                                    .frame(maxWidth: .infinity)
                            }
                            .buttonStyle(.bordered)
                        }
                        .controlSize(.regular)
                    }
                }
                .padding(24)
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
                .sheet(isPresented: $showingSnoozeSheet) {
                    SnoozeSheet(amount: $snoozeAmount, unit: $snoozeUnit) {
                        Task { await viewModel.snooze(reminder, amount: snoozeAmount, unit: snoozeUnit) }
                    }
                }
            } else {
                ContentUnavailableView(
                    "All Clear",
                    systemImage: "checkmark.circle",
                    description: Text("You have no pending reminders.")
                )
            }

            Spacer()

            Button {
                Task { await viewModel.refresh() }
            } label: {
                Label("Refresh", systemImage: "arrow.clockwise")
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .padding(.bottom, 8)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct SnoozeSheet: View {
    @Binding var amount: Int
    @Binding var unit: SnoozeUnit
    var onConfirm: () -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            HStack(spacing: 0) {
                Picker("Amount", selection: $amount) {
                    ForEach(1...30, id: \.self) { n in
                        Text("\(n)").tag(n)
                    }
                }
                .pickerStyle(.wheel)

                Picker("Unit", selection: $unit) {
                    ForEach(SnoozeUnit.allCases) { unit in
                        Text(unit.pluralized(for: amount)).tag(unit)
                    }
                }
                .pickerStyle(.wheel)
            }
            .labelsHidden()
            .navigationTitle("Snooze")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Snooze") {
                        onConfirm()
                        dismiss()
                    }
                }
            }
        }
        .presentationDetents([.height(260)])
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
