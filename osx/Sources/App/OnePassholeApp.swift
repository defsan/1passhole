import SwiftUI
import SwiftData

@main
struct OnePassholeApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var appState = AppState()

    init() {
        UserDefaults.standard.register(defaults: [
            SettingsKey.clipboardTimeout: 300,
            SettingsKey.lockOnSleep: true,
            SettingsKey.lockOnScreenSaver: true,
            SettingsKey.autoLockTimeout: 5,
            SettingsKey.theme: "system",
            SettingsKey.sidebarIconSize: "medium",
            SettingsKey.compactMode: false,
            SettingsKey.storageMode: "local",
        ])
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(appState)
                .modelContainer(appState.modelContainer)
                .onAppear {
                    let theme = UserDefaults.standard.string(forKey: SettingsKey.theme) ?? "system"
                    AppearanceSettingsTab.applyTheme(theme)
                }
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 900, height: 600)

        Settings {
            SettingsView()
                .environment(appState)
                .modelContainer(appState.modelContainer)
        }
    }
}
