import SwiftUI

/// Dedicated detail-view row for a `.totp` field, used in place of `DetailFieldRow`.
/// Shows a live, auto-refreshing code with a countdown ring rather than the raw secret —
/// the underlying secret is never displayed here, only the ephemeral code it produces.
/// Ticks every second via `TimelineView`, the first periodic-refresh UI in the app.
struct TOTPFieldRow: View {
    let field: ItemField
    let onCopy: (String) -> Void

    var body: some View {
        if let config = TOTPConfig.parse(from: field.value) {
            TimelineView(.periodic(from: .now, by: 1)) { context in
                let code = TOTPGenerator.code(for: config, at: context.date)
                let remaining = TOTPGenerator.secondsRemaining(period: config.period, at: context.date)
                row(code: code, remaining: remaining, period: config.period)
            }
        } else {
            invalidRow
        }
    }

    @ViewBuilder
    private func row(code: String, remaining: Int, period: TimeInterval) -> some View {
        HStack(alignment: .top, spacing: 8) {
            VStack(alignment: .leading, spacing: 3) {
                Text(field.label.lowercased())
                    .font(.subheadline)
                    .foregroundStyle(.tint)

                Text(groupedCode(code))
                    .font(.system(.title2, design: .monospaced))
                    .textSelection(.enabled)
            }

            Spacer()

            HStack(spacing: 10) {
                CountdownRing(remaining: remaining, period: period)

                Button {
                    onCopy(code)
                } label: {
                    Image(systemName: "doc.on.doc")
                        .font(.system(size: 24))
                }
                .buttonStyle(.borderless)
            }
        }
        .padding(.vertical, 10)
        .padding(.horizontal, 4)
        .contentShape(Rectangle())
        .onTapGesture {
            onCopy(code)
        }
    }

    private var invalidRow: some View {
        HStack(alignment: .top, spacing: 8) {
            VStack(alignment: .leading, spacing: 3) {
                Text(field.label.lowercased())
                    .font(.subheadline)
                    .foregroundStyle(.tint)
                Label("Invalid one-time password secret", systemImage: "exclamationmark.triangle")
                    .font(.body)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(.vertical, 10)
        .padding(.horizontal, 4)
    }

    /// Splits an even-length code in half with a space (e.g. "123456" -> "123 456"),
    /// matching how authenticator apps conventionally display TOTP codes.
    private func groupedCode(_ code: String) -> String {
        guard code.count > 3 else { return code }
        let mid = code.index(code.startIndex, offsetBy: code.count / 2)
        return "\(code[..<mid]) \(code[mid...])"
    }
}

private struct CountdownRing: View {
    let remaining: Int
    let period: TimeInterval

    private var progress: Double {
        period > 0 ? Double(remaining) / period : 0
    }

    var body: some View {
        ZStack {
            Circle()
                .stroke(.secondary.opacity(0.25), lineWidth: 2.5)
            Circle()
                .trim(from: 0, to: progress)
                .stroke(
                    progress < (1.0 / 5) ? .red : Color.accentColor,
                    style: StrokeStyle(lineWidth: 2.5, lineCap: .round)
                )
                .rotationEffect(.degrees(-90))
            Text("\(remaining)")
                .font(.system(size: 9, weight: .medium, design: .rounded))
        }
        .frame(width: 26, height: 26)
        .animation(.linear(duration: 1), value: remaining)
    }
}
