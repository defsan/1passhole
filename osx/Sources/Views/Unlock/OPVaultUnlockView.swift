import SwiftUI

/// Unlocks one OPVault connection with its own master password — a separate secret
/// from 1Passhole's own, since this is a foreign vault being opened live.
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

            Text("Enter the master password for this 1Password vault.")
                .font(.callout)
                .foregroundStyle(.secondary)

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
                appState.opvaultSessions[connection.id] = session
                password = ""
            } catch {
                errorMessage = error.localizedDescription
            }
            isProcessing = false
        }
    }
}
