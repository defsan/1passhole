import Foundation
import CryptoKit

/// RFC 4648 base32 decoding — TOTP secrets are conventionally base32-encoded, whether
/// bare or embedded in an `otpauth://` URI's `secret` query parameter. Padding ('=') and
/// whitespace are tolerated and ignored; matching is case-insensitive.
enum Base32 {
    private static let alphabet = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZ234567")
    private static let charMap: [Character: UInt8] = {
        var map: [Character: UInt8] = [:]
        for (index, char) in alphabet.enumerated() {
            map[char] = UInt8(index)
        }
        return map
    }()

    static func decode(_ string: String) -> Data? {
        let cleaned = string.uppercased().filter { $0 != "=" && !$0.isWhitespace }
        guard !cleaned.isEmpty else { return nil }

        var bits = 0
        var buffer: UInt64 = 0
        var output = [UInt8]()

        for char in cleaned {
            guard let value = charMap[char] else { return nil }
            buffer = (buffer << 5) | UInt64(value)
            bits += 5
            if bits >= 8 {
                bits -= 8
                output.append(UInt8((buffer >> UInt64(bits)) & 0xFF))
            }
        }
        return Data(output)
    }
}

enum TOTPAlgorithm: String {
    case sha1
    case sha256
    case sha512
}

/// A fully-resolved TOTP configuration — everything `TOTPGenerator` needs to compute a
/// code, with 1Password/RFC-6238-standard defaults filled in for anything unspecified.
struct TOTPConfig: Equatable {
    var secret: Data
    var algorithm: TOTPAlgorithm
    var digits: Int
    var period: TimeInterval

    /// Parses either a full `otpauth://totp/...?secret=...` URI (1Password 7+'s format)
    /// or a bare base32 secret with no URI wrapper (older/legacy clients) — both shapes
    /// are confirmed real-world OPVault field values. Missing `algorithm`/`digits`/`period`
    /// default to SHA1/6/30s, matching RFC 6238 and the fallback other OPVault-reading
    /// clients (e.g. KeePassXC) use for the bare-secret case. Returns `nil` rather than
    /// guessing when the secret isn't valid base32 — this is external/user-entered data
    /// crossing a trust boundary, not something to silently paper over.
    static func parse(from rawValue: String) -> TOTPConfig? {
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        if trimmed.lowercased().hasPrefix("otpauth://"), let url = URL(string: trimmed) {
            let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
            func value(_ name: String) -> String? {
                items.first { $0.name == name }?.value
            }
            guard let secretString = value("secret"), let secret = Base32.decode(secretString) else {
                return nil
            }
            let algorithm = TOTPAlgorithm(rawValue: value("algorithm")?.lowercased() ?? "sha1") ?? .sha1
            let digits = value("digits").flatMap(Int.init) ?? 6
            let period = value("period").flatMap(TimeInterval.init) ?? 30
            return TOTPConfig(secret: secret, algorithm: algorithm, digits: digits, period: period)
        }

        guard let secret = Base32.decode(trimmed) else { return nil }
        return TOTPConfig(secret: secret, algorithm: .sha1, digits: 6, period: 30)
    }
}

/// RFC 6238 (TOTP) / RFC 4226 (HOTP) code generation. Pure, no I/O — the counter is
/// derived from wall-clock time, everything else is deterministic.
enum TOTPGenerator {
    static func code(for config: TOTPConfig, at date: Date = .now) -> String {
        let counter = UInt64(date.timeIntervalSince1970 / config.period)
        let counterBytes = withUnsafeBytes(of: counter.bigEndian) { Data($0) }
        let key = SymmetricKey(data: config.secret)

        let hmac: Data
        switch config.algorithm {
        case .sha1:
            hmac = Data(HMAC<Insecure.SHA1>.authenticationCode(for: counterBytes, using: key))
        case .sha256:
            hmac = Data(HMAC<SHA256>.authenticationCode(for: counterBytes, using: key))
        case .sha512:
            hmac = Data(HMAC<SHA512>.authenticationCode(for: counterBytes, using: key))
        }

        let offset = Int(hmac[hmac.count - 1] & 0x0f)
        let truncated = (UInt32(hmac[offset] & 0x7f) << 24)
            | (UInt32(hmac[offset + 1]) << 16)
            | (UInt32(hmac[offset + 2]) << 8)
            | UInt32(hmac[offset + 3])

        let modulus = UInt32(pow(10.0, Double(config.digits)))
        let codeValue = truncated % modulus
        return String(format: "%0\(config.digits)d", codeValue)
    }

    /// Seconds until the current code expires — drives the countdown ring in the UI.
    static func secondsRemaining(period: TimeInterval, at date: Date = .now) -> Int {
        let elapsed = date.timeIntervalSince1970.truncatingRemainder(dividingBy: period)
        return Int(period - elapsed)
    }
}
