import SwiftUI

struct ReminderListView: View {
    @Environment(RemindersViewModel.self) private var viewModel

    let title: String
    let items: [ReminderItem]

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
