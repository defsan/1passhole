import SwiftUI

struct UnlockView: View {
    @Environment(AppState.self) private var appState

    @State private var password = ""
    @State private var isProcessing = false
    @State private var errorMessage: String?
    @State private var attemptedTouchID = false

    @FocusState private var passwordFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            Spacer()

            VStack(spacing: 24) {
                Image(systemName: "lock.fill")
                    .font(.system(size: 48))
                    .foregroundStyle(.tint)

                Text("1passhole")
                    .font(.title.weight(.bold))

                Text("Enter your master password to unlock.")
                    .font(.callout)
                    .foregroundStyle(.secondary)

                VStack(spacing: 12) {
                    SecureField("Master password", text: $password)
                        .focused($passwordFocused)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit { unlockWithPassword() }
                        .frame(width: 300)

                    if let errorMessage {
                        Label(errorMessage, systemImage: "xmark.circle.fill")
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                }

                HStack(spacing: 12) {
                    Button("Unlock") {
                        unlockWithPassword()
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .disabled(password.isEmpty || isProcessing)

                    if appState.authService.isTouchIDEnrolled {
                        Button {
                            unlockWithTouchID()
                        } label: {
                            Image(systemName: "touchid")
                                .font(.title2)
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.large)
                    }
                }

                if isProcessing {
                    ProgressView()
                        .controlSize(.small)
                }
            }
            .padding(40)

            Spacer()
        }
        .frame(minWidth: 500, minHeight: 400)
        .onAppear {
            passwordFocused = true
            if appState.authService.isTouchIDEnrolled && !attemptedTouchID {
                attemptedTouchID = true
                unlockWithTouchID()
            }
        }
    }

    private func unlockWithPassword() {
        guard !password.isEmpty, !isProcessing else { return }
        isProcessing = true
        errorMessage = nil

        Task {
            do {
                let masterKey = try appState.authService.unlock(password: password)
                appState.unlock(with: masterKey)
                password = ""
            } catch {
                errorMessage = error.localizedDescription
            }
            isProcessing = false
        }
    }

    private func unlockWithTouchID() {
        guard !isProcessing else { return }
        isProcessing = true
        errorMessage = nil

        Task {
            do {
                let masterKey = try await appState.authService.unlockWithTouchID()
                appState.unlock(with: masterKey)
            } catch {
                errorMessage = "Touch ID failed. Enter your master password."
                passwordFocused = true
            }
            isProcessing = false
        }
    }
}
