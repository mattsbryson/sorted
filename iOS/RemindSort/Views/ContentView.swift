import SwiftUI

struct ContentView: View {
    @Environment(RemindersViewModel.self) private var viewModel

    var body: some View {
        Group {
            switch viewModel.loadState {
            case .idle, .loading:
                ProgressView("Loading reminders…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            case .accessDenied:
                AccessDeniedView()
            case .error(let message):
                ContentUnavailableView("Something Went Wrong", systemImage: "exclamationmark.triangle", description: Text(message))
            case .needsAccess, .loaded:
                tabs
            }
        }
        .task {
            await viewModel.start()
        }
    }

    private var tabs: some View {
        TabView {
            HomeView()
                .tabItem { Label("Home", systemImage: "star.fill") }

            ReminderListView(title: "Today", items: viewModel.todayItems) { item in
                viewModel.skipToday(item)
            }
            .tabItem { Label("Today", systemImage: "sun.max.fill") }

            ReminderListView(title: "Upcoming", items: viewModel.upcomingItems)
                .tabItem { Label("Upcoming", systemImage: "calendar") }

            ReminderListView(title: "Someday", items: viewModel.somedayItems)
                .tabItem { Label("Someday", systemImage: "tray.fill") }
        }
    }
}

private struct AccessDeniedView: View {
    var body: some View {
        ContentUnavailableView(
            "Reminders Access Needed",
            systemImage: "list.bullet.clipboard",
            description: Text("Grant RemindSort access to Reminders in System Settings > Privacy & Security > Reminders, then relaunch the app.")
        )
    }
}
