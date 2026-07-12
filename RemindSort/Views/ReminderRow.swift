import SwiftUI

struct PriorityBadge: View {
    let level: ReminderPriorityLevel

    var body: some View {
        if level != .none {
            Text(level.rawValue.capitalized)
                .font(.caption2.weight(.semibold))
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(color.opacity(0.18), in: Capsule())
                .foregroundStyle(color)
        }
    }

    private var color: Color {
        switch level {
        case .high: .red
        case .medium: .orange
        case .low: .blue
        case .none: .clear
        }
    }
}

struct ReminderRow: View {
    let reminder: ReminderItem
    var onComplete: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Button(action: onComplete) {
                Image(systemName: "circle")
                    .foregroundStyle(.secondary)
                    .font(.title3)
            }
            .buttonStyle(.plain)

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(reminder.title)
                        .font(.body)
                    if reminder.isFlagged {
                        Image(systemName: "flag.fill")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                    PriorityBadge(level: reminder.priorityLevel)
                }

                HStack(spacing: 8) {
                    Text(reminder.listName)
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    if let due = reminder.dueDate {
                        Text(due.formatted(date: .abbreviated, time: .shortened))
                            .font(.caption)
                            .foregroundStyle(reminder.isOverdue ? .red : .secondary)
                    }
                }

                if let notes = reminder.notes, !notes.isEmpty {
                    Text(notes)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }

            Spacer()
        }
        .padding(.vertical, 4)
    }
}
