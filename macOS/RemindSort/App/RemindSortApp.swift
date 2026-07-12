import SwiftUI

@main
struct RemindSortApp: App {
    @State private var viewModel = RemindersViewModel()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(viewModel)
                .environment(viewModel.settings)
                .frame(minWidth: 480, minHeight: 620)
        }
        .windowResizability(.contentSize)
    }
}
