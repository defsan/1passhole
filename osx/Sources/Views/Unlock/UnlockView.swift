import SwiftUI

struct UnlockView: View {
    @Environment(AppState.self) private var appState

    @State private var password = ""
    @State private var isProcessing = false
    @State private var errorMessage: String?
    @State private var attemptedTouchID = false
    @State private var showPassword = false

    @FocusState private var passwordFocused: Bool

    var body: some View {
        HStack(spacing: 0) {
            // Left panel — app icon
            ZStack {
                Color(.windowBackgroundColor)
                    .opacity(0.6)

                VStack(spacing: 16) {
                    ZStack {
                        Circle()
                            .fill(.ultraThinMaterial)
                            .frame(width: 100, height: 100)

                        Circle()
                            .strokeBorder(
                                LinearGradient(
                                    colors: [.blue, .blue.opacity(0.6)],
                                    startPoint: .top,
                                    endPoint: .bottom
                                ),
                                lineWidth: 4
                            )
                            .frame(width: 100, height: 100)

                        Image(systemName: "lock.shield.fill")
                            .font(.system(size: 38, weight: .medium))
                            .foregroundStyle(.primary)
                    }

                    if appState.authService.isTouchIDEnrolled {
                        Button {
                            unlockWithTouchID()
                        } label: {
                            Image(systemName: "touchid")
                                .font(.system(size: 28))
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                        .padding(.top, 8)
                    }
                }
            }
            .frame(width: 240)

            // Right panel — password entry
            ZStack {
                VStack(spacing: 20) {
                    Spacer()

                    Text("1passhole")
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(.secondary)

                    VStack(spacing: 8) {
                        HStack(spacing: 4) {
                            Group {
                                if showPassword {
                                    TextField("Enter your password", text: $password)
                                } else {
                                    SecureField("Enter your password", text: $password)
                                }
                            }
                            .focused($passwordFocused)
                            .textFieldStyle(.plain)
                            .font(.system(size: 20))
                            .onSubmit { unlockWithPassword() }

                            Button {
                                showPassword.toggle()
                            } label: {
                                Image(systemName: showPassword ? "eye.slash" : "eye")
                                    .font(.system(size: 16))
                                    .foregroundStyle(.secondary)
                                    .frame(width: 34, height: 34)
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)

                            Button {
                                unlockWithPassword()
                            } label: {
                                Image(systemName: "arrow.right")
                                    .font(.system(size: 16, weight: .semibold))
                                    .foregroundStyle(.white)
                                    .frame(width: 34, height: 34)
                                    .background(
                                        RoundedRectangle(cornerRadius: 6)
                                            .fill(password.isEmpty ? Color.gray : Color.accentColor)
                                    )
                            }
                            .buttonStyle(.plain)
                            .disabled(password.isEmpty || isProcessing)
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background {
                            RoundedRectangle(cornerRadius: 10)
                                .strokeBorder(.separator, lineWidth: 1)
                        }
                        .frame(width: 320)

                        if let errorMessage {
                            Text(errorMessage)
                                .font(.caption)
                                .foregroundStyle(.red)
                                .frame(width: 320, alignment: .leading)
                        }
                    }

                    if isProcessing {
                        ProgressView()
                            .controlSize(.small)
                    }

                    Spacer()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(minWidth: 560, minHeight: 380)
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
                errorMessage = "Touch ID failed. Enter your password."
                passwordFocused = true
            }
            isProcessing = false
        }
    }
}
