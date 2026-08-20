import SwiftUI

struct ContentView: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        switch appState.lockState {
        case .needsSetup:
            SetupView()
        case .locked:
            UnlockView()
        case .unlocked:
            MainView()
        }
    }
}
