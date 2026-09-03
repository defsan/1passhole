import SwiftUI

/// Sheet for adding or replacing a `.totp` field — same presentation pattern as
/// `PasswordGeneratorView`. Accepts either a full `otpauth://` URI or a bare base32
/// secret, validating live via `TOTPConfig.parse` before allowing save so an invalid
/// value can't be saved into the item.
struct TOTPSetupView: View {
    var onSave: (String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var input = ""

    private var parsedConfig: TOTPConfig? {
        TOTPConfig.parse(from: input)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("One-Time Password")
                    .font(.headline)
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
            .padding()

            Divider()

            VStack(alignment: .leading, spacing: 12) {
                Text("Paste a setup key or otpauth:// URI")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)

                TextField("Secret or otpauth:// URI", text: $input)
                    .textFieldStyle(.roundedBorder)

                if !input.isEmpty {
                    if let config = parsedConfig {
                        Label("Valid — code right now is \(TOTPGenerator.code(for: config))", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                            .font(.caption)
                    } else {
                        Label("Not a valid secret or otpauth:// URI", systemImage: "xmark.circle.fill")
                            .foregroundStyle(.red)
                            .font(.caption)
                    }
                }
            }
            .padding()

            Divider()

            HStack {
                Spacer()
                Button("Save") {
                    onSave(input.trimmingCharacters(in: .whitespacesAndNewlines))
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(parsedConfig == nil)
            }
            .padding()
        }
        .frame(width: 420)
    }
}
