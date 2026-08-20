import SwiftUI

struct GeneralSettingsTab: View {
    @AppStorage(SettingsKey.clipboardTimeout) private var clipboardTimeout: Int = 300
    @AppStorage(SettingsKey.lockOnSleep) private var lockOnSleep: Bool = true
    @AppStorage(SettingsKey.lockOnScreenSaver) private var lockOnScreenSaver: Bool = true
    @AppStorage(SettingsKey.autoLockTimeout) private var autoLockTimeout: Int = 5

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            Text("General")
                .font(.title2.weight(.semibold))

            VStack(alignment: .leading, spacing: 16) {
                Text("Security")
                    .font(.headline)

                Toggle("Lock when the system goes to sleep", isOn: $lockOnSleep)
                    .toggleStyle(.checkbox)

                Toggle("Lock when the screen saver starts", isOn: $lockOnScreenSaver)
                    .toggleStyle(.checkbox)

                HStack {
                    Text("Auto-lock after:")
                    Picker("", selection: $autoLockTimeout) {
                        Text("1 minute").tag(1)
                        Text("5 minutes").tag(5)
                        Text("15 minutes").tag(15)
                        Text("30 minutes").tag(30)
                        Text("1 hour").tag(60)
                        Text("Never").tag(0)
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .frame(width: 140)
                }
            }

            Divider()

            VStack(alignment: .leading, spacing: 16) {
                Text("Clipboard")
                    .font(.headline)

                HStack {
                    Text("Clear clipboard after:")
                    Picker("", selection: $clipboardTimeout) {
                        Text("30 seconds").tag(30)
                        Text("1 minute").tag(60)
                        Text("2 minutes").tag(120)
                        Text("5 minutes").tag(300)
                        Text("10 minutes").tag(600)
                        Text("Never").tag(0)
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .frame(width: 140)
                }

                Text("Copied passwords and fields will be automatically removed from the clipboard.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(24)
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }
}
