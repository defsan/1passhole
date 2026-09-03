import SwiftUI

private enum SetupStep {
    case chooseVault
    case newVaultPassword
}

/// Setup only ever *establishes* credentials — it never unlocks the app itself. Once a
/// native password is created, or an OPVault connection is picked, this transitions
/// `AppState.lockState` to `.locked` and steps out of the way: `ContentView` then shows
/// the ordinary `UnlockView`, the same screen used on every later launch, which already
/// knows how to unlock either kind of vault. There is no separate "unlock" screen here.
struct SetupView: View {
    @State private var step: SetupStep = .chooseVault

    var body: some View {
        switch step {
        case .chooseVault:
            ChooseVaultStep(onNewVault: { step = .newVaultPassword })
        case .newVaultPassword:
            NewVaultPasswordStep()
        }
    }
}

// MARK: - Step 1: create new vault, or connect an existing 1Password vault

private struct ChooseVaultStep: View {
    var onNewVault: () -> Void

    @Environment(AppState.self) private var appState
    @State private var isProcessing = false
    @State private var errorMessage: String?

    var body: some View {
        VStack(spacing: 0) {
            Spacer()

            VStack(spacing: 24) {
                Image(systemName: "tray.full.fill")
                    .font(.system(size: 48))
                    .foregroundStyle(.tint)

                Text("Get Started")
                    .font(.title2.weight(.semibold))

                Text("Create a new vault, or connect a 1Password vault you already have.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 380)

                HStack(spacing: 16) {
                    ChoiceCard(
                        icon: "lock.shield",
                        title: "New Vault",
                        subtitle: "Start fresh with a native 1passhole vault.",
                        action: onNewVault
                    )
                    ChoiceCard(
                        icon: "person.badge.key.fill",
                        title: "1Password Vault",
                        subtitle: "Connect an existing .opvault (e.g. in Dropbox).",
                        action: connectOPVault
                    )
                }
                .frame(maxWidth: 480)

                if isProcessing {
                    ProgressView().controlSize(.small)
                }

                if let errorMessage {
                    Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                        .font(.callout)
                        .foregroundStyle(.red)
                }
            }
            .padding(40)

            Spacer()
        }
        .frame(minWidth: 560, minHeight: 420)
    }

    /// Just registers the connection (bookmark + profile) and hands off to `UnlockView` —
    /// no password is entered or verified here; that's `UnlockView`'s job, same as it
    /// would be for any other launch.
    private func connectOPVault() {
        guard !isProcessing else { return }
        errorMessage = nil
        guard let pickedURL = OPVaultLocator.pickVaultFolder() else { return }
        defer { pickedURL.stopAccessingSecurityScopedResource() }
        let folderURL = OPVaultLocator.resolveVaultBundle(from: pickedURL)

        isProcessing = true
        let profiles = OPVaultLocator.profileNames(in: folderURL)
        guard let profileName = profiles.first else {
            errorMessage = "No 1Password profile found in that folder."
            isProcessing = false
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
            appState.lockState = .locked
        } catch {
            errorMessage = error.localizedDescription
            isProcessing = false
        }
    }
}

private struct ChoiceCard: View {
    let icon: String
    let title: String
    let subtitle: String
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            VStack(spacing: 12) {
                Image(systemName: icon)
                    .font(.system(size: 30))
                    .foregroundStyle(.tint)
                Text(title)
                    .font(.headline)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .padding(20)
            .frame(maxWidth: .infinity)
            .frame(height: 160)
            .background {
                RoundedRectangle(cornerRadius: 12)
                    .fill(isHovering ? Color.accentColor.opacity(0.12) : Color(.controlBackgroundColor))
                    .stroke(.separator, lineWidth: 1)
            }
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
    }
}

// MARK: - Step 2: master password, for a brand-new native vault

private struct NewVaultPasswordStep: View {
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
                        Text("Continue")
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

    /// Only creates the credential (Keychain salt/hash + optional Touch ID enrollment) and
    /// hands off to `UnlockView` — it does not unlock the app or create the first vault
    /// itself; `AppState.unlock(with:)` creates the default "Personal" vault the first
    /// time a native unlock actually succeeds.
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

                password = ""
                confirmPassword = ""
                appState.lockState = .locked
            } catch {
                errorMessage = error.localizedDescription
            }
            isProcessing = false
        }
    }
}
