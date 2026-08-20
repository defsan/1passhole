import SwiftUI
import AppKit

struct AppearanceSettingsTab: View {
    @AppStorage(SettingsKey.theme) private var theme: String = "system"
    @AppStorage(SettingsKey.sidebarIconSize) private var sidebarIconSize: String = "medium"
    @AppStorage(SettingsKey.compactMode) private var compactMode: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            Text("Appearance")
                .font(.title2.weight(.semibold))

            VStack(alignment: .leading, spacing: 16) {
                Text("Theme")
                    .font(.headline)

                Picker("", selection: $theme) {
                    Text("System").tag("system")
                    Text("Light").tag("light")
                    Text("Dark").tag("dark")
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .frame(width: 240)

                Text("Choose how 1passhole looks on your Mac.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Divider()

            VStack(alignment: .leading, spacing: 16) {
                Text("Layout")
                    .font(.headline)

                HStack {
                    Text("Sidebar icon size:")
                    Picker("", selection: $sidebarIconSize) {
                        Text("Small").tag("small")
                        Text("Medium").tag("medium")
                        Text("Large").tag("large")
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .frame(width: 120)
                }

                Toggle("Compact mode", isOn: $compactMode)
                    .toggleStyle(.checkbox)

                Text("Reduces spacing in lists and sidebars.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(24)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .onChange(of: theme) {
            AppearanceSettingsTab.applyTheme(theme)
        }
    }

    static func applyTheme(_ theme: String) {
        switch theme {
        case "light":
            NSApp.appearance = NSAppearance(named: .aqua)
        case "dark":
            NSApp.appearance = NSAppearance(named: .darkAqua)
        default:
            NSApp.appearance = nil
        }
    }
}
