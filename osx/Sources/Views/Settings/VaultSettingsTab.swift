import SwiftUI
import AppKit

struct VaultSettingsTab: View {
    @Environment(AppState.self) private var appState
    @AppStorage(SettingsKey.storageMode) private var storageMode: String = "local"
    @State private var touchIDEnabled = false
    @State private var errorMessage: String?
    @State private var showRestartAlert = false

    private var isUnlocked: Bool {
        appState.lockState == .unlocked
    }

    private var isICloudAvailable: Bool {
        FileManager.default.ubiquityIdentityToken != nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            Text("Vault")
                .font(.title2.weight(.semibold))

            VStack(alignment: .leading, spacing: 16) {
                Text("Storage")
                    .font(.headline)

                HStack {
                    Text("Store vault data:")
                    Picker("", selection: $storageMode) {
                        Text("On My Mac").tag("local")
                        Text("iCloud").tag("icloud")
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .frame(width: 160)
                    .disabled(!isICloudAvailable && storageMode == "local")
                }

                if !isICloudAvailable && storageMode == "local" {
                    Label("Sign in to iCloud in System Settings to enable sync.", systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(.orange)
                } else if storageMode == "icloud" {
                    Label("Vaults sync across your devices via iCloud. Master password is per-device.", systemImage: "info.circle")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Label("Vault data is stored only on this Mac.", systemImage: "info.circle")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Divider()

            VStack(alignment: .leading, spacing: 16) {
                Text("Biometrics")
                    .font(.headline)

                if appState.authService.isTouchIDAvailable {
                    Toggle("Unlock with Touch ID", isOn: touchIDBinding)
                        .toggleStyle(.checkbox)
                        .disabled(!isUnlocked)

                    if !isUnlocked {
                        Label("Unlock 1passhole to change Touch ID settings.", systemImage: "lock.fill")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    if let errorMessage {
                        Label(errorMessage, systemImage: "exclamationmark.triangle")
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                } else {
                    HStack(spacing: 6) {
                        Image(systemName: "touchid")
                            .foregroundStyle(.secondary)
                        Text("Touch ID is not available on this Mac.")
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .padding(24)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .onAppear {
            touchIDEnabled = appState.authService.isTouchIDEnrolled
        }
        .onChange(of: storageMode) {
            showRestartAlert = true
        }
        .alert("Restart Required", isPresented: $showRestartAlert) {
            Button("Quit Now") {
                NSApplication.shared.terminate(nil)
            }
            Button("Later", role: .cancel) { }
        } message: {
            Text("Quit and reopen 1passhole for the storage change to take effect.")
        }
    }

    private var touchIDBinding: Binding<Bool> {
        Binding(
            get: { touchIDEnabled },
            set: { newValue in
                errorMessage = nil
                do {
                    if newValue {
                        let masterKeyData = try appState.cryptoEngine.getMasterKeyData()
                        try appState.authService.enrollTouchID(masterKey: masterKeyData)
                    } else {
                        try appState.authService.unenrollTouchID()
                    }
                    touchIDEnabled = newValue
                } catch {
                    errorMessage = error.localizedDescription
                }
            }
        )
    }
}
