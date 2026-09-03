import Foundation
import CryptoKit
import CommonCrypto

/// Cryptographic primitives for the AgileBits OPVault format (legacy 1Password 4-6 /
/// Dropbox-synced vaults). This mirrors, byte-for-byte, the algorithm validated
/// externally in `scripts/opvault_tool.py` (PBKDF2-HMAC-SHA512 → SHA-512 → split
/// enc/mac keys, `opdata01` = AES-256-CBC + HMAC-SHA256, per-item key wrapping,
/// and the confirmed item-level `hmac` formula).
///
/// This type has no file or SwiftData knowledge — it only transforms `Data` in and
/// out, so it can be tested and reasoned about independently of I/O.
enum OPVaultError: LocalizedError {
    case badMagic
    case macMismatch
    case truncatedData
    case wrongPassword

    var errorDescription: String? {
        switch self {
        case .badMagic: "Not a valid opdata01 block"
        case .macMismatch: "HMAC verification failed (wrong password or corrupted data)"
        case .truncatedData: "Encrypted block is too short to be valid"
        case .wrongPassword: "Wrong master password (or corrupt profile)"
        }
    }
}

enum OPVaultCrypto {
    // MARK: - AES-256-CBC (no padding; opdata01 manages its own padding)

    private static func aesCBC(
        operation: Int,
        key: Data,
        iv: Data,
        input: Data
    ) -> Data {
        var output = Data(count: input.count + kCCBlockSizeAES128)
        var outputMoved = 0

        let status = output.withUnsafeMutableBytes { outBuf -> CCCryptorStatus in
            input.withUnsafeBytes { inBuf in
                iv.withUnsafeBytes { ivBuf in
                    key.withUnsafeBytes { keyBuf in
                        CCCrypt(
                            CCOperation(operation),
                            CCAlgorithm(kCCAlgorithmAES),
                            CCOptions(0), // no padding, plain CBC (opdata01 manages its own block-aligned padding)
                            keyBuf.baseAddress, keyBuf.count,
                            ivBuf.baseAddress,
                            inBuf.baseAddress, inBuf.count,
                            outBuf.baseAddress, outBuf.count,
                            &outputMoved
                        )
                    }
                }
            }
        }
        precondition(status == kCCSuccess, "AES-CBC operation failed with status \(status)")
        return output.prefix(outputMoved)
    }

    static func aesCBCEncrypt(key: Data, iv: Data, plaintext: Data) -> Data {
        aesCBC(operation: kCCEncrypt, key: key, iv: iv, input: plaintext)
    }

    static func aesCBCDecrypt(key: Data, iv: Data, ciphertext: Data) -> Data {
        aesCBC(operation: kCCDecrypt, key: key, iv: iv, input: ciphertext)
    }

    // MARK: - PBKDF2-HMAC-SHA512

    /// Derive `derivedLength` bytes via PBKDF2 with HMAC-SHA512 as the PRF.
    /// For the 64-byte output OPVault needs, this is exactly one PBKDF2 block
    /// (dkLen == hLen for SHA-512), so no block-index looping is required.
    static func pbkdf2SHA512(password: Data, salt: Data, iterations: Int, derivedLength: Int = 64) -> Data {
        precondition(derivedLength <= 64, "single-block PBKDF2 helper only supports up to 64 bytes")
        let key = SymmetricKey(data: password)

        var salted = salt
        salted.append(contentsOf: [0, 0, 0, 1]) // block index 1, big-endian UInt32

        var u = Data(HMAC<SHA512>.authenticationCode(for: salted, using: key))
        var result = u
        if iterations > 1 {
            for _ in 2...iterations {
                u = Data(HMAC<SHA512>.authenticationCode(for: u, using: key))
                for i in 0..<result.count {
                    result[i] ^= u[i]
                }
            }
        }
        return result.prefix(derivedLength)
    }

    // MARK: - opdata01

    private static let opdata01Magic = Data("opdata01".utf8)

    /// Encrypt `plaintext` into an opdata01 block: magic(8) || length(8, LE) || iv(16) || ciphertext || hmac(32).
    static func opdata01Encrypt(plaintext: Data, encKey: Data, macKey: Data) -> Data {
        let plainLen = UInt64(plaintext.count)
        let padLen = (16 - (plaintext.count % 16)) % 16
        var padded = Data(count: padLen)
        if padLen > 0 {
            _ = padded.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, padLen, $0.baseAddress!) }
        }
        padded.append(plaintext)

        var iv = Data(count: 16)
        _ = iv.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, 16, $0.baseAddress!) }

        let ciphertext = aesCBCEncrypt(key: encKey, iv: iv, plaintext: padded)

        var header = opdata01Magic
        withUnsafeBytes(of: plainLen.littleEndian) { header.append(contentsOf: $0) }
        header.append(iv)

        let mac = Data(HMAC<SHA256>.authenticationCode(for: header + ciphertext, using: SymmetricKey(data: macKey)))
        return header + ciphertext + mac
    }

    /// Decrypt and authenticate an opdata01 block.
    static func opdata01Decrypt(_ blob: Data, encKey: Data, macKey: Data) throws -> Data {
        guard blob.count >= 32 + 32 else { throw OPVaultError.truncatedData }
        let bytes = Data(blob) // ensure zero-based indexing
        guard bytes.prefix(8) == opdata01Magic else { throw OPVaultError.badMagic }

        let plainLen = bytes.subdata(in: 8..<16).withUnsafeBytes { $0.load(as: UInt64.self) }.littleEndian
        let iv = bytes.subdata(in: 16..<32)
        let ciphertext = bytes.subdata(in: 32..<(bytes.count - 32))
        let storedMac = bytes.subdata(in: (bytes.count - 32)..<bytes.count)
        let header = bytes.subdata(in: 0..<(bytes.count - 32))

        let valid = HMAC<SHA256>.isValidAuthenticationCode(
            storedMac,
            authenticating: header,
            using: SymmetricKey(data: macKey)
        )
        guard valid else { throw OPVaultError.macMismatch }

        let padded = aesCBCDecrypt(key: encKey, iv: iv, ciphertext: ciphertext)
        guard plainLen <= padded.count else { throw OPVaultError.truncatedData }
        return padded.suffix(Int(plainLen))
    }

    // MARK: - Item key wrap/unwrap ("k" field)

    /// Wrap a 32-byte item enc key + 32-byte item mac key with the master key pair.
    /// Layout: iv(16) || AES-CBC(itemEnc||itemMac)(64) || HMAC-SHA256(32).
    static func wrapItemKey(masterEnc: Data, masterMac: Data, itemEnc: Data, itemMac: Data) -> Data {
        var iv = Data(count: 16)
        _ = iv.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, 16, $0.baseAddress!) }
        let ciphertext = aesCBCEncrypt(key: masterEnc, iv: iv, plaintext: itemEnc + itemMac)
        let mac = Data(HMAC<SHA256>.authenticationCode(for: iv + ciphertext, using: SymmetricKey(data: masterMac)))
        return iv + ciphertext + mac
    }

    static func unwrapItemKey(masterEnc: Data, masterMac: Data, blob: Data) throws -> (enc: Data, mac: Data) {
        guard blob.count == 16 + 64 + 32 else { throw OPVaultError.truncatedData }
        let bytes = Data(blob)
        let iv = bytes.subdata(in: 0..<16)
        let ciphertext = bytes.subdata(in: 16..<80)
        let storedMac = bytes.subdata(in: 80..<112)

        let valid = HMAC<SHA256>.isValidAuthenticationCode(
            storedMac,
            authenticating: iv + ciphertext,
            using: SymmetricKey(data: masterMac)
        )
        guard valid else { throw OPVaultError.macMismatch }

        let decrypted = aesCBCDecrypt(key: masterEnc, iv: iv, ciphertext: ciphertext)
        guard decrypted.count == 64 else { throw OPVaultError.truncatedData }
        return (decrypted.prefix(32), decrypted.suffix(32))
    }

    // MARK: - Profile-level master/overview key derivation

    /// `profile.masterKey`/`profile.overviewKey` unwrap to 64 bytes each, but that raw
    /// material is not the enc/mac pair directly — 1Password additionally hashes it
    /// with SHA-512 first, then splits *that* digest into enc(first32)/mac(last32).
    /// (This was the root cause of an early implementation bug — see scripts/opvault_tool.py
    /// history / conversation notes: the profile-level opdata01 HMAC only authenticates the
    /// ciphertext, not the plaintext, so a wrong split silently "succeeds" there while every
    /// item then fails.)
    static func deriveEncMacKeys(fromDecryptedProfileKey plaintext: Data) -> (enc: Data, mac: Data) {
        let digest = Data(SHA512.hash(data: plaintext))
        return (digest.prefix(32), digest.suffix(32))
    }

    // MARK: - Confirmed item `hmac` field

    /// The item-level integrity `hmac`: HMAC-SHA256 (keyed with the overview MAC key) over
    /// the sorted-by-key concatenation of every envelope field except `hmac` itself, with
    /// each value stringified the way a JS serializer would (`true`/`false`/`null`, plain
    /// decimal for numbers, verbatim for strings). Confirmed empirically against every
    /// non-trashed item in a real vault via `scripts/opvault_tool.py verify-hmac`
    /// (trashed items carry a stale hmac from whatever old client trashed them — a known,
    /// pre-existing inconsistency, not part of this formula).
    ///
    /// Callers pass already-JS-stringified values (see `OPVaultJSONValue.jsString`)
    /// so this function stays free of any JSON-value-type knowledge.
    static func computeItemHMAC(sortedFieldsExcludingHMAC fields: [String: String], overviewMac: Data) -> Data {
        let concatenated = fields.keys.sorted().map { key in key + fields[key]! }.joined()
        return Data(HMAC<SHA256>.authenticationCode(for: Data(concatenated.utf8), using: SymmetricKey(data: overviewMac)))
    }
}
