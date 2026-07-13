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
    /// Adds a search field filtering by title, notes, and list name. Used
    /// for Upcoming and Someday, where lists grow long; Today is already a
    /// short curated slice.
    var searchable: Bool = false

    @State private var searchText = ""

    private var visibleItems: [ReminderItem] {
        let query = searchText.trimmingCharacters(in: .whitespaces)
        guard searchable, !query.isEmpty else { return items }
        return items.filter { item in
            item.title.localizedCaseInsensitiveContains(query)
                || (item.notes?.localizedCaseInsensitiveContains(query) ?? false)
                || item.listName.localizedCaseInsensitiveContains(query)
        }
    }

    var body: some View {
        NavigationStack {
            content
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

    @ViewBuilder private var content: some View {
        if searchable {
            listOrEmpty
                .searchable(text: $searchText, prompt: "Search reminders")
        } else {
            listOrEmpty
        }
    }

    @ViewBuilder private var listOrEmpty: some View {
        if visibleItems.isEmpty {
            if searchable, !searchText.trimmingCharacters(in: .whitespaces).isEmpty {
                ContentUnavailableView.search(text: searchText)
            } else {
                ContentUnavailableView(
                    "Nothing Here",
                    systemImage: "checkmark.circle",
                    description: Text("No reminders in this list right now.")
                )
            }
        } else {
            List {
                ForEach(visibleItems) { item in
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
}
