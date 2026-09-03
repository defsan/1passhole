import Testing
import Foundation
@testable import OnePasshole

struct TOTPGeneratorTests {
    // MARK: - Base32 (RFC 4648 Appendix B test vectors)

    @Test func base32DecodesRFC4648Vectors() {
        #expect(Base32.decode("MY======") == Data("f".utf8))
        #expect(Base32.decode("MZXQ====") == Data("fo".utf8))
        #expect(Base32.decode("MZXW6===") == Data("foo".utf8))
        #expect(Base32.decode("MZXW6YQ=") == Data("foob".utf8))
        #expect(Base32.decode("MZXW6YTB") == Data("fooba".utf8))
        #expect(Base32.decode("MZXW6YTBOI======") == Data("foobar".utf8))
    }

    @Test func base32DecodeIsCaseInsensitiveAndIgnoresWhitespace() {
        #expect(Base32.decode("mzxw6ytb") == Data("fooba".utf8))
        #expect(Base32.decode(" MZXW 6YTB ") == Data("fooba".utf8))
    }

    @Test func base32DecodeRejectsInvalidCharacters() {
        #expect(Base32.decode("not-valid-base32!!!") == nil)
        #expect(Base32.decode("") == nil)
    }

    // MARK: - RFC 6238 Appendix B test vectors
    //
    // Secrets are ASCII "12345678901234567890" (SHA1), repeated to 32 bytes (SHA256), and
    // to 64 bytes (SHA512); T0=0, step=30s, 8-digit codes. Verified independently against
    // Python's stdlib hmac/hashlib rather than trusting a single source.

    private static let sha1Secret = Data("12345678901234567890".utf8)
    private static let sha256Secret = Data("12345678901234567890123456789012".utf8)
    private static let sha512Secret = Data("1234567890123456789012345678901234567890123456789012345678901234".utf8)

    private struct Vector {
        let time: TimeInterval
        let sha1: String
        let sha256: String
        let sha512: String
    }

    private static let vectors: [Vector] = [
        Vector(time: 59, sha1: "94287082", sha256: "46119246", sha512: "90693936"),
        Vector(time: 1_111_111_109, sha1: "07081804", sha256: "68084774", sha512: "25091201"),
        Vector(time: 1_111_111_111, sha1: "14050471", sha256: "67062674", sha512: "99943326"),
        Vector(time: 1_234_567_890, sha1: "89005924", sha256: "91819424", sha512: "93441116"),
        Vector(time: 2_000_000_000, sha1: "69279037", sha256: "90698825", sha512: "38618901"),
        Vector(time: 20_000_000_000, sha1: "65353130", sha256: "77737706", sha512: "47863826"),
    ]

    @Test func rfc6238VectorsSHA1() {
        for vector in Self.vectors {
            let config = TOTPConfig(secret: Self.sha1Secret, algorithm: .sha1, digits: 8, period: 30)
            let code = TOTPGenerator.code(for: config, at: Date(timeIntervalSince1970: vector.time))
            #expect(code == vector.sha1)
        }
    }

    @Test func rfc6238VectorsSHA256() {
        for vector in Self.vectors {
            let config = TOTPConfig(secret: Self.sha256Secret, algorithm: .sha256, digits: 8, period: 30)
            let code = TOTPGenerator.code(for: config, at: Date(timeIntervalSince1970: vector.time))
            #expect(code == vector.sha256)
        }
    }

    @Test func rfc6238VectorsSHA512() {
        for vector in Self.vectors {
            let config = TOTPConfig(secret: Self.sha512Secret, algorithm: .sha512, digits: 8, period: 30)
            let code = TOTPGenerator.code(for: config, at: Date(timeIntervalSince1970: vector.time))
            #expect(code == vector.sha512)
        }
    }

    @Test func secondsRemainingCountsDownWithinPeriod() {
        #expect(TOTPGenerator.secondsRemaining(period: 30, at: Date(timeIntervalSince1970: 0)) == 30)
        #expect(TOTPGenerator.secondsRemaining(period: 30, at: Date(timeIntervalSince1970: 29)) == 1)
        #expect(TOTPGenerator.secondsRemaining(period: 30, at: Date(timeIntervalSince1970: 30)) == 30)
    }

    // MARK: - TOTPConfig.parse

    @Test func parsesBareBase32SecretWithDefaults() throws {
        let config = try #require(TOTPConfig.parse(from: "JBSWY3DPEHPK3PXP"))
        #expect(config.algorithm == .sha1)
        #expect(config.digits == 6)
        #expect(config.period == 30)
        #expect(config.secret == Base32.decode("JBSWY3DPEHPK3PXP"))
    }

    @Test func parsesOtpauthURIWithExplicitParams() throws {
        let uri = "otpauth://totp/Example:alice@example.com?secret=JBSWY3DPEHPK3PXP&issuer=Example&algorithm=SHA256&digits=8&period=60"
        let config = try #require(TOTPConfig.parse(from: uri))
        #expect(config.algorithm == .sha256)
        #expect(config.digits == 8)
        #expect(config.period == 60)
        #expect(config.secret == Base32.decode("JBSWY3DPEHPK3PXP"))
    }

    @Test func parsesOtpauthURIWithMissingParamsUsingDefaults() throws {
        // Real 1Password 7+ data doesn't always append digits=/period= — must default,
        // matching the fallback other OPVault-reading clients use.
        let uri = "otpauth://totp/Example:alice@example.com?secret=JBSWY3DPEHPK3PXP&issuer=Example"
        let config = try #require(TOTPConfig.parse(from: uri))
        #expect(config.algorithm == .sha1)
        #expect(config.digits == 6)
        #expect(config.period == 30)
    }

    @Test func parseRejectsInvalidSecret() {
        #expect(TOTPConfig.parse(from: "not-valid-base32!!!") == nil)
        #expect(TOTPConfig.parse(from: "otpauth://totp/Example?secret=not-valid-base32!!!") == nil)
        #expect(TOTPConfig.parse(from: "") == nil)
        #expect(TOTPConfig.parse(from: "   ") == nil)
    }

    @Test func parseRejectsOtpauthURIWithNoSecret() {
        #expect(TOTPConfig.parse(from: "otpauth://totp/Example?issuer=Example") == nil)
    }
}
