import SwiftUI

/// The Face Off tab (shown when enabled in Settings): presents two reminders
/// and asks the user to pick the more important one, recording each choice as
/// explicit pairwise training data via `FaceOffLog`. Cross-platform — one
/// implementation for both apps.
struct FaceOffView: View {
    @Environment(RemindersViewModel.self) private var viewModel

    var body: some View {
        NavigationStack {
            Group {
                if let pair = viewModel.faceOffPair {
                    comparison(pair)
                } else {
                    ContentUnavailableView(
                        "Not Enough Reminders",
                        systemImage: "square.on.square.dashed",
                        description: Text("Add at least two reminders to compare them here.")
                    )
                }
            }
            .navigationTitle("Face Off")
        }
        .onAppear { viewModel.startFaceOff() }
    }

    private func comparison(_ pair: (ReminderItem, ReminderItem)) -> some View {
        VStack(spacing: 14) {
            VStack(spacing: 4) {
                Text("Which is more important?")
                    .font(.headline)
                Text("Tap the one you'd rather get done. Your picks train the ranking.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .padding(.bottom, 2)

            FaceOffCard(reminder: pair.0) {
                viewModel.chooseFaceOff(winner: pair.0, loser: pair.1)
            }

            Text("vs")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)

            FaceOffCard(reminder: pair.1) {
                viewModel.chooseFaceOff(winner: pair.1, loser: pair.0)
            }

            Button("Too close / skip pair") {
                viewModel.skipFaceOffPair()
            }
            .buttonStyle(.borderless)
            .font(.callout)
            .padding(.top, 2)

            if viewModel.faceOffCount > 0 {
                Text("^[\(viewModel.faceOffCount) comparison](inflect: true) recorded this session")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding()
        .frame(maxWidth: 480)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// One tappable reminder card in a face-off. Shows the human-relevant
/// context (title, list, notes, due date) but deliberately *not* the app's
/// own urgency score — the judgment should be the user's, unanchored by what
/// the current ranking already thinks.
private struct FaceOffCard: View {
    let reminder: ReminderItem
    let onPick: () -> Void

    var body: some View {
        Button(action: onPick) {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text(reminder.listName)
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(.quaternary, in: Capsule())
                    Spacer()
                    if let due = reminder.dueDate {
                        Text(due.formatted(date: .abbreviated, time: .omitted))
                            .font(.caption)
                            .foregroundStyle(reminder.isOverdue ? .red : .secondary)
                    }
                }

                Text(reminder.title)
                    .font(.title3.weight(.semibold))
                    .multilineTextAlignment(.leading)
                    .foregroundStyle(.primary)

                if let notes = reminder.notes, !notes.isEmpty {
                    Text(notes)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding()
            .background(
                RoundedRectangle(cornerRadius: 14)
                    .fill(Color.primary.opacity(0.06))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 14)
                    .strokeBorder(Color.primary.opacity(0.08))
            )
            .contentShape(RoundedRectangle(cornerRadius: 14))
        }
        .buttonStyle(.plain)
    }
}
