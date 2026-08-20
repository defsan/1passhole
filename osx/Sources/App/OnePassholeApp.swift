import SwiftUI
import SwiftData

@main
struct OnePassholeApp: App {
    @State private var appState = AppState()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(appState)
                .modelContainer(appState.modelContainer)
        }
        .windowStyle(.titleBar)
        .defaultSize(width: 900, height: 600)
    }
}
