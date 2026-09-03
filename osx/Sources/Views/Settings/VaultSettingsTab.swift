import SwiftUI
import SwiftData
import AppKit

struct VaultSettingsTab: View {
    @Environment(AppState.self) private var appState
    @Query(sort: \Vault.name) private var vaults: [Vault]
    @Query(sort: \OPVaultConnection.name) private var opvaultConnections: [OPVaultConnection]
    @AppStorage(SettingsKey.storageMode) private var storageMode: String = "local"
    @State private var touchIDEnabled = false
    @State private var errorMessage: String?
    @State private var showRestartAlert = false
    @State private var opvaultError: String?
    @State private var vaultError: String?
    @State private var showingNewVault = false
    @State private var newVaultName = ""
    @State private var vaultToRename: Vault?
    @State private var renameText = ""

    private var isUnlocked: Bool {
        appState.lockState == .unlocked
    }

    private var isICloudAvailable: Bool {
        FileManager.default.ubiquityIdentityToken != nil
    }

    /// Resolves the persisted recent-vault refs against the live query results, dropping
    /// any that point at a vault/connection since deleted.
    private var recentVaultEntries: [SelectedVault] {
        appState.recentVaults.compactMap { ref in
            switch ref.kind {
            case .native:
                vaults.first { $0.id == ref.id }.map(SelectedVault.native)
            case .opvault:
                opvaultConnections.first { $0.id == ref.id }.map(SelectedVault.opvault)
            }
        }
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

            Divider()

            if !recentVaultEntries.isEmpty {
                VStack(alignment: .leading, spacing: 16) {
                    Text("Recent Vaults")
                        .font(.headline)

                    ForEach(Array(recentVaultEntries.enumerated()), id: \.offset) { _, entry in
                        HStack(spacing: 10) {
                            Image(systemName: entry.iconName)
                                .foregroundStyle(.tint)
                            Text(entry.name)
                            Spacer()
                            Button("Switch To") {
                                appState.switchVault(to: entry)
                            }
                            .disabled(appState.selectedVault == entry)
                        }
                    }
                }

                Divider()
            }

            VStack(alignment: .leading, spacing: 16) {
                Text("Vaults")
                    .font(.headline)

                ForEach(vaults) { vault in
                    HStack(spacing: 10) {
                        Image(systemName: vault.iconName)
                            .foregroundStyle(.tint)
                        Text(vault.name)
                        Spacer()
                        Button("Switch To") {
                            appState.switchVault(to: .native(vault))
                        }
                        .disabled(appState.selectedVault == .native(vault))
                        Button("Rename…") {
                            renameText = vault.name
                            vaultToRename = vault
                        }
                        .disabled(!isUnlocked)
                        Button("Delete", role: .destructive) {
                            deleteVault(vault)
                        }
                        .disabled(!isUnlocked)
                    }
                }

                Button("New Vault…") {
                    newVaultName = ""
                    showingNewVault = true
                }
                .disabled(!isUnlocked)

                if !isUnlocked {
                    Label("Unlock 1passhole to manage vaults.", systemImage: "lock.fill")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                if let vaultError {
                    Label(vaultError, systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }

            Divider()

            VStack(alignment: .leading, spacing: 16) {
                Text("1Password Vault")
                    .font(.headline)

                Text("Connect an existing 1Password vault (.opvault, usually inside Dropbox) to browse and edit it live, alongside your native vaults.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                ForEach(opvaultConnections) { connection in
                    HStack(spacing: 10) {
                        Image(systemName: connection.iconName)
                            .foregroundStyle(.tint)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(connection.name)
                            Text("Profile: \(connection.profileName)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Switch To") {
                            appState.switchVault(to: .opvault(connection))
                        }
                        .disabled(appState.selectedVault == .opvault(connection))
                        Button("Disconnect", role: .destructive) {
                            disconnectOPVault(connection)
                        }
                    }
                }

                Button(opvaultConnections.isEmpty ? "Connect 1Password Vault…" : "Connect Another…") {
                    connectOPVault()
                }
                .disabled(!isUnlocked)

                if !isUnlocked {
                    Label("Unlock 1passhole to manage 1Password vault connections.", systemImage: "lock.fill")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                if let opvaultError {
                    Label(opvaultError, systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(.red)
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
        .alert("New Vault", isPresented: $showingNewVault) {
            TextField("Vault name", text: $newVaultName)
            Button("Create") { createVault() }
            Button("Cancel", role: .cancel) { newVaultName = "" }
        }
        .alert(
            "Rename Vault",
            isPresented: Binding(
                get: { vaultToRename != nil },
                set: { if !$0 { vaultToRename = nil } }
            )
        ) {
            TextField("Vault name", text: $renameText)
            Button("Rename") {
                if let vault = vaultToRename { renameVault(vault) }
            }
            Button("Cancel", role: .cancel) { vaultToRename = nil }
        }
    }

    private func createVault() {
        vaultError = nil
        guard !newVaultName.isEmpty else { return }
        let service = VaultService(modelContext: appState.modelContainer.mainContext, crypto: appState.cryptoEngine)
        do {
            _ = try service.createVault(name: newVaultName)
        } catch {
            vaultError = error.localizedDescription
        }
        newVaultName = ""
    }

    private func renameVault(_ vault: Vault) {
        vaultError = nil
        guard !renameText.isEmpty else { return }
        let service = VaultService(modelContext: appState.modelContainer.mainContext, crypto: appState.cryptoEngine)
        do {
            try service.renameVault(vault, to: renameText)
        } catch {
            vaultError = error.localizedDescription
        }
        vaultToRename = nil
    }

    private func deleteVault(_ vault: Vault) {
        vaultError = nil
        let service = VaultService(modelContext: appState.modelContainer.mainContext, crypto: appState.cryptoEngine)
        if appState.selectedVault == .native(vault) {
            appState.selectedVault = nil
        }
        do {
            try service.deleteVault(vault)
        } catch {
            vaultError = error.localizedDescription
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

    private func connectOPVault() {
        opvaultError = nil
        guard let pickedURL = OPVaultLocator.pickVaultFolder() else { return }
        defer { pickedURL.stopAccessingSecurityScopedResource() }
        let folderURL = OPVaultLocator.resolveVaultBundle(from: pickedURL)

        let profiles = OPVaultLocator.profileNames(in: folderURL)
        guard let profileName = profiles.first else {
            opvaultError = "No 1Password profile found in that folder."
            return
        }

        do {
            let bookmark = try OPVaultLocator.makeBookmark(for: folderURL)
            let connection = OPVaultConnection(
                name: folderURL.deletingPathExtension().lastPathComponent,
                bookmarkData: bookmark,
                profileName: profileName
            )
            appState.modelContainer.mainContext.insert(connection)
            try appState.modelContainer.mainContext.save()
            appState.switchVault(to: .opvault(connection))
        } catch {
            opvaultError = error.localizedDescription
        }
    }

    private func disconnectOPVault(_ connection: OPVaultConnection) {
        if appState.selectedVault == .opvault(connection) {
            appState.selectedVault = nil
        }
        appState.opvaultSessions.removeValue(forKey: connection.id)
        appState.modelContainer.mainContext.delete(connection)
        try? appState.modelContainer.mainContext.save()
    }
}
