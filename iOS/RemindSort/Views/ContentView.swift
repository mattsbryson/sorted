import SwiftUI

struct ContentView: View {
    @Environment(RemindersViewModel.self) private var viewModel

    var body: some View {
        Group {
            switch viewModel.loadState {
            case .idle:
                // Brief (permission check + EventKit fetch only) — no progress
                // bar/messaging here, that's reserved for an actual AI pass.
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color(.systemBackground))
            case .loading:
                LoadingView(progress: viewModel.rankingProgress)
            case .accessDenied:
                AccessDeniedView()
            case .error(let message):
                ContentUnavailableView("Something Went Wrong", systemImage: "exclamationmark.triangle", description: Text(message))
            case .needsAccess, .loaded:
                tabs
            }
        }
        .background(Color(.systemBackground))
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

private struct LoadingView: View {
    let progress: Double

    var body: some View {
        VStack(spacing: 16) {
            ProgressView(value: progress)
                .progressViewStyle(.linear)
                .frame(maxWidth: 240)

            Text("Reminders are being processed and sorted…")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(.systemBackground))
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
