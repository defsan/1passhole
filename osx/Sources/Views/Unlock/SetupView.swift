import SwiftUI

struct SetupView: View {
    @Environment(AppState.self) private var appState

    @State private var password = ""
    @State private var confirmPassword = ""
    @State private var isProcessing = false
    @State private var errorMessage: String?
    @State private var enableTouchID = true

    @FocusState private var focusedField: Field?
    private enum Field { case password, confirm }

    private var passwordsMatch: Bool { password == confirmPassword }
    private var isValid: Bool { password.count >= 8 && passwordsMatch }

    var body: some View {
        VStack(spacing: 0) {
            Spacer()

            VStack(spacing: 24) {
                Image(systemName: "lock.shield.fill")
                    .font(.system(size: 48))
                    .foregroundStyle(.tint)

                Text("Create Master Password")
                    .font(.title2.weight(.semibold))

                Text("This password encrypts everything in 1passhole.\nThere is no recovery — if you forget it, your data is gone.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 380)

                VStack(spacing: 12) {
                    SecureField("Master password", text: $password)
                        .focused($focusedField, equals: .password)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit { focusedField = .confirm }

                    SecureField("Confirm password", text: $confirmPassword)
                        .focused($focusedField, equals: .confirm)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit { submit() }

                    if password.count > 0 && password.count < 8 {
                        Label("Minimum 8 characters", systemImage: "exclamationmark.triangle")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }

                    if confirmPassword.count > 0 && !passwordsMatch {
                        Label("Passwords don't match", systemImage: "xmark.circle")
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                }
                .frame(width: 300)

                if appState.authService.isTouchIDAvailable {
                    Toggle("Enable Touch ID unlock", isOn: $enableTouchID)
                        .toggleStyle(.checkbox)
                        .font(.callout)
                }

                if let errorMessage {
                    Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                        .font(.callout)
                        .foregroundStyle(.red)
                }

                Button(action: submit) {
                    if isProcessing {
                        ProgressView()
                            .controlSize(.small)
                            .frame(width: 160)
                    } else {
                        Text("Create Vault")
                            .frame(width: 160)
                    }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(!isValid || isProcessing)
            }
            .padding(40)

            Spacer()
        }
        .frame(minWidth: 500, minHeight: 450)
        .onAppear { focusedField = .password }
    }

    private func submit() {
        guard isValid, !isProcessing else { return }
        isProcessing = true
        errorMessage = nil

        Task {
            do {
                let masterKey = try appState.authService.setup(password: password)

                if enableTouchID && appState.authService.isTouchIDAvailable {
                    try appState.authService.enrollTouchID(masterKey: masterKey)
                }

                let vaultService = VaultService(
                    modelContext: appState.modelContainer.mainContext,
                    crypto: appState.cryptoEngine
                )
                appState.unlock(with: masterKey)
                _ = try vaultService.createVault(name: "Personal")

                password = ""
                confirmPassword = ""
            } catch {
                errorMessage = error.localizedDescription
            }
            isProcessing = false
        }
    }
}
