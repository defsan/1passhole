import SwiftUI

/// A 1Password vault waiting to be connected (or re-matched) through `OPVaultPasswordSheet`.
struct PendingOPVault: Identifiable {
    let id = UUID()
    let connection: OPVaultConnection
    /// False when re-matching a connection that already exists (its password differed).
    let isNew: Bool
}

/// Enforces one password for everything: a 1Password vault can only be connected when
/// its password is the 1Passhole master password. When it differs, offers to change the
/// master password to the vault's (re-wrapping native vault keys, so nothing is lost).
struct OPVaultPasswordSheet: View {
    let pending: PendingOPVault

    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss

    private enum Step {
        case vaultPassword
        /// The vault opened, but with a password other than the master password.
        case mismatch(session: OPVaultSession)
    }

    @State private var step: Step = .vaultPassword
    @State private var vaultPassword = ""
    @State private var currentMasterPassword = ""
    @State private var errorMessage: String?
    @State private var isProcessing = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label(pending.connection.name, systemImage: pending.connection.iconName)
                .font(.headline)

            switch step {
            case .vaultPassword:
                Text("Enter this 1Password vault's password. It must be the same as your 1Passhole master password — one password unlocks everything.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                SecureField("1Password vault password", text: $vaultPassword)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(submitVaultPassword)

            case .mismatch:
                Text("This vault's password is different from your 1Passhole master password.")
                    .font(.callout.weight(.medium))
                Text("To keep one password for everything, change your 1Passhole master password to this vault's password. Your native vaults are re-encrypted with the new password; nothing is lost.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if UserDefaults.standard.string(forKey: SettingsKey.storageMode) == "icloud" {
                    Label("Your vaults sync via iCloud — other Macs will need the new master password too.", systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }

                SecureField("Current 1Passhole master password", text: $currentMasterPassword)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(changeMasterPasswordAndConnect)
            }

            if let errorMessage {
                Label(errorMessage, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                if isProcessing {
                    ProgressView().controlSize(.small)
                }
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                switch step {
                case .vaultPassword:
                    Button(pending.isNew ? "Connect" : "Check Password", action: submitVaultPassword)
                        .keyboardShortcut(.defaultAction)
                        .disabled(vaultPassword.isEmpty || isProcessing)
                case .mismatch:
                    Button("Change Master Password", action: changeMasterPasswordAndConnect)
                        .keyboardShortcut(.defaultAction)
                        .disabled(currentMasterPassword.isEmpty || isProcessing)
                }
            }
        }
        .padding(20)
        .frame(width: 420)
    }

    private func submitVaultPassword() {
        guard !vaultPassword.isEmpty, !isProcessing else { return }
        errorMessage = nil
        isProcessing = true
        defer { isProcessing = false }

        let session: OPVaultSession
        do {
            session = try OPVaultService.unlock(connection: pending.connection, password: vaultPassword)
        } catch OPVaultServiceError.wrongPassword {
            errorMessage = "That isn't this 1Password vault's password."
            return
        } catch {
            errorMessage = error.localizedDescription
            return
        }

        if appState.isMasterPassword(vaultPassword) {
            finish(with: session)
        } else if appState.isOPVaultPrimary {
            errorMessage = "This vault's password differs from your primary 1Password vault's, which is your master password. Only vaults with the same password can be connected."
        } else {
            step = .mismatch(session: session)
        }
    }

    private func changeMasterPasswordAndConnect() {
        guard case .mismatch(let session) = step, !currentMasterPassword.isEmpty, !isProcessing else { return }
        errorMessage = nil
        isProcessing = true
        defer { isProcessing = false }

        do {
            try appState.changeMasterPassword(current: currentMasterPassword, to: vaultPassword)
        } catch AuthError.wrongPassword {
            errorMessage = "Incorrect current master password."
            return
        } catch {
            errorMessage = error.localizedDescription
            return
        }
        finish(with: session)
    }

    private func finish(with session: OPVaultSession) {
        do {
            try appState.addOPVaultConnection(pending.connection, session: session)
            vaultPassword = ""
            currentMasterPassword = ""
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
