import SwiftUI

@main
struct SortedApp: App {
    @State private var viewModel = RemindersViewModel()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(viewModel)
                .environment(viewModel.settings)
        }
    }
}
