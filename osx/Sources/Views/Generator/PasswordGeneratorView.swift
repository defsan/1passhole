import SwiftUI

struct PasswordGeneratorView: View {
    var onSelect: ((String) -> Void)?

    @Environment(\.dismiss) private var dismiss

    @State private var mode: GeneratorMode = .random
    @State private var generatedPassword = ""

    // Random mode
    @State private var length: Double = 24
    @State private var includeUppercase = true
    @State private var includeLowercase = true
    @State private var includeDigits = true
    @State private var includeSymbols = true

    // Passphrase mode
    @State private var wordCount: Double = 4
    @State private var separator = "-"
    @State private var capitalize = true

    enum GeneratorMode: String, CaseIterable {
        case random = "Random"
        case passphrase = "Passphrase"
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Password Generator")
                    .font(.headline)
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
            .padding()

            Divider()

            VStack(spacing: 16) {
                // Generated password display
                HStack {
                    Text(generatedPassword)
                        .font(.system(.body, design: .monospaced))
                        .textSelection(.enabled)
                        .lineLimit(2)
                        .frame(maxWidth: .infinity, alignment: .leading)

                    Button {
                        ClipboardService.copy(generatedPassword)
                    } label: {
                        Image(systemName: "doc.on.doc")
                    }
                    .buttonStyle(.borderless)

                    Button {
                        generate()
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .buttonStyle(.borderless)
                }
                .padding(12)
                .background(.background.secondary)
                .clipShape(RoundedRectangle(cornerRadius: 8))

                // Mode picker
                Picker("Mode", selection: $mode) {
                    ForEach(GeneratorMode.allCases, id: \.self) { m in
                        Text(m.rawValue).tag(m)
                    }
                }
                .pickerStyle(.segmented)

                // Options
                switch mode {
                case .random:
                    VStack(alignment: .leading, spacing: 12) {
                        HStack {
                            Text("Length: \(Int(length))")
                            Slider(value: $length, in: 8...128, step: 1)
                        }
                        Toggle("Uppercase (A-Z)", isOn: $includeUppercase)
                        Toggle("Lowercase (a-z)", isOn: $includeLowercase)
                        Toggle("Digits (0-9)", isOn: $includeDigits)
                        Toggle("Symbols (!@#$...)", isOn: $includeSymbols)
                    }
                    .toggleStyle(.checkbox)

                case .passphrase:
                    VStack(alignment: .leading, spacing: 12) {
                        HStack {
                            Text("Words: \(Int(wordCount))")
                            Slider(value: $wordCount, in: 3...10, step: 1)
                        }
                        HStack {
                            Text("Separator:")
                            TextField("", text: $separator)
                                .textFieldStyle(.roundedBorder)
                                .frame(width: 60)
                        }
                        Toggle("Capitalize words", isOn: $capitalize)
                            .toggleStyle(.checkbox)
                    }
                }
            }
            .padding()

            Divider()

            HStack {
                Spacer()
                if onSelect != nil {
                    Button("Use Password") {
                        onSelect?(generatedPassword)
                        dismiss()
                    }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                }
            }
            .padding()
        }
        .frame(width: 420)
        .onAppear { generate() }
        .onChange(of: mode) { generate() }
        .onChange(of: length) { generate() }
        .onChange(of: includeUppercase) { generate() }
        .onChange(of: includeLowercase) { generate() }
        .onChange(of: includeDigits) { generate() }
        .onChange(of: includeSymbols) { generate() }
        .onChange(of: wordCount) { generate() }
        .onChange(of: separator) { generate() }
        .onChange(of: capitalize) { generate() }
    }

    private func generate() {
        switch mode {
        case .random:
            generatedPassword = PasswordGenerator.random(
                length: Int(length),
                uppercase: includeUppercase,
                lowercase: includeLowercase,
                digits: includeDigits,
                symbols: includeSymbols
            )
        case .passphrase:
            generatedPassword = PasswordGenerator.passphrase(
                wordCount: Int(wordCount),
                separator: separator,
                capitalize: capitalize
            )
        }
    }
}
