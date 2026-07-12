import SwiftUI

struct ReminderListView: View {
    @Environment(RemindersViewModel.self) private var viewModel

    let title: String
    let items: [ReminderItem]
    /// When set, rows can be swiped from the trailing edge (swipe left, same
    /// direction as Mail/Reminders' own swipe actions) to skip them
    /// (session-only — doesn't touch Reminders — and lets the next-ranked
    /// item take their place). Used for the Today tab.
    var onSkip: ((ReminderItem) -> Void)? = nil

    var body: some View {
        NavigationStack {
            Group {
                if items.isEmpty {
                    ContentUnavailableView(
                        "Nothing Here",
                        systemImage: "checkmark.circle",
                        description: Text("No reminders in this list right now.")
                    )
                } else {
                    List {
                        ForEach(items) { item in
                            ReminderRow(reminder: item) {
                                Task { await viewModel.complete(item) }
                            } onDelete: {
                                Task { await viewModel.delete(item) }
                            }
                            .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                                if let onSkip {
                                    Button {
                                        onSkip(item)
                                    } label: {
                                        Label("Skip", systemImage: "arrow.uturn.forward.circle")
                                    }
                                    .tint(.blue)
                                }
                            }
                        }
                    }
                }
            }
            .navigationTitle(title)
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
}
