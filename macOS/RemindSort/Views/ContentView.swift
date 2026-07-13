import SwiftUI

struct ContentView: View {
    @Environment(RemindersViewModel.self) private var viewModel

    var body: some View {
        Group {
            switch viewModel.loadState {
            case .idle, .loading:
                // One full-screen loading view from the very first frame
                // through the AI pass — idle (permission check) and loading
                // (fetch + ranking) look identical, so there's never a blank
                // window in between.
                LoadingView()
            case .accessDenied:
                AccessDeniedView()
            case .error(let message):
                ContentUnavailableView("Something Went Wrong", systemImage: "exclamationmark.triangle", description: Text(message))
            case .needsAccess, .loaded:
                tabs
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
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

            ReminderListView(title: "Upcoming", items: viewModel.upcomingItems, searchable: true)
                .tabItem { Label("Upcoming", systemImage: "calendar") }

            ReminderListView(title: "Someday", items: viewModel.somedayItems, searchable: true)
                .tabItem { Label("Someday", systemImage: "tray.fill") }
        }
    }
}

private struct LoadingView: View {
    var body: some View {
        VStack(spacing: 16) {
            ProgressView()
                .controlSize(.large)

            Text("Reminders are being processed and sorted…")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .windowBackgroundColor))
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
