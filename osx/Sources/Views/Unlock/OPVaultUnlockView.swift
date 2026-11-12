import SwiftUI

/// Fallback prompt for one OPVault connection that the master-password unlock couldn't
/// open — its password differs from the master password, its folder was unreachable at
/// unlock, or (after Touch ID) no saved keys exist for it yet.
struct OPVaultUnlockView: View {
    let connection: OPVaultConnection

    @Environment(AppState.self) private var appState
    @State private var password = ""
    @State private var isProcessing = false
    @State private var errorMessage: String?
    @FocusState private var passwordFocused: Bool

    var body: some View {
        VStack(spacing: 16) {
            Spacer()

            Image(systemName: "person.badge.key.fill")
                .font(.system(size: 40))
                .foregroundStyle(.tint)

            Text(connection.name)
                .font(.title3.weight(.semibold))

            if appState.opvaultPasswordMismatches.contains(connection.id) {
                Text("This vault's password is different from your 1Passhole master password.\nEnter it here, or make them match in Settings → Vault.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            } else {
                Text("Enter your master password to open this 1Password vault.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            SecureField("Master password", text: $password)
                .textFieldStyle(.roundedBorder)
                .frame(width: 260)
                .focused($passwordFocused)
                .onSubmit { unlock() }

            if let errorMessage {
                Text(errorMessage)
                    .font(.caption)
                    .foregroundStyle(.red)
            }

            Button {
                unlock()
            } label: {
                if isProcessing {
                    ProgressView().controlSize(.small)
                } else {
                    Text("Unlock")
                }
            }
            .buttonStyle(.borderedProminent)
            .disabled(password.isEmpty || isProcessing)

            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear { passwordFocused = true }
    }

    private func unlock() {
        guard !password.isEmpty, !isProcessing else { return }
        isProcessing = true
        errorMessage = nil

        Task {
            do {
                let session = try OPVaultService.unlock(connection: connection, password: password)
                appState.didUnlockOPVaultSeparately(connection, session: session)
                password = ""
            } catch {
                errorMessage = error.localizedDescription
            }
            isProcessing = false
        }
    }
}
