import SwiftUI

@main
struct CursorDBCleanerApp: App {
    @StateObject private var state = AppState()

    var body: some Scene {
        WindowGroup {
            ContentView(state: state)
        }
        .windowStyle(.automatic)
        .windowResizability(.contentSize)
        .defaultSize(width: 520, height: 560)
        .commands {
            CommandGroup(replacing: .newItem) {}
        }
    }
}
