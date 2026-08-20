import Foundation
import CryptoKit

enum CryptoError: LocalizedError {
    case encryptionFailed
    case decryptionFailed
    case invalidSealedBox
    case masterKeyNotSet
    case keyDerivationFailed

    var errorDescription: String? {
        switch self {
        case .encryptionFailed: "Encryption failed"
        case .decryptionFailed: "Decryption failed — wrong password?"
        case .invalidSealedBox: "Invalid encrypted data"
        case .masterKeyNotSet: "Vault is locked"
        case .keyDerivationFailed: "Key derivation failed"
        }
    }
}

/// Handles all encryption/decryption using AES-256-GCM.
///
/// Key hierarchy:
///   Master password → (Argon2id) → Master key
///   Master key encrypts → Vault keys (one per vault)
///   Vault key encrypts → Item payloads
@Observable
final class CryptoEngine {
    private var masterKey: SymmetricKeyData?

    var isUnlocked: Bool { masterKey != nil }

    // MARK: - Master key management

    func setMasterKey(_ key: SymmetricKeyData) {
        self.masterKey = key
    }

    func clearKeys() {
        self.masterKey = nil
    }

    func getMasterKey() throws -> SymmetricKey {
        guard let masterKey else { throw CryptoError.masterKeyNotSet }
        return masterKey.symmetricKey
    }

    func getMasterKeyData() throws -> SymmetricKeyData {
        guard let masterKey else { throw CryptoError.masterKeyNotSet }
        return masterKey
    }

    // MARK: - Key generation

    /// Generate a new random 256-bit symmetric key.
    static func generateKey() -> SymmetricKeyData {
        SymmetricKeyData(key: SymmetricKey(size: .bits256))
    }

    // MARK: - AES-256-GCM encrypt/decrypt

    /// Encrypt plaintext data. Returns combined representation: nonce || ciphertext || tag.
    func encrypt(_ plaintext: Data, using key: SymmetricKey) throws -> Data {
        do {
            let sealedBox = try AES.GCM.seal(plaintext, using: key)
            guard let combined = sealedBox.combined else {
                throw CryptoError.encryptionFailed
            }
            return combined
        } catch is CryptoError {
            throw CryptoError.encryptionFailed
        } catch {
            throw CryptoError.encryptionFailed
        }
    }

    /// Decrypt combined sealed box data (nonce || ciphertext || tag).
    func decrypt(_ ciphertext: Data, using key: SymmetricKey) throws -> Data {
        do {
            let sealedBox = try AES.GCM.SealedBox(combined: ciphertext)
            return try AES.GCM.open(sealedBox, using: key)
        } catch {
            throw CryptoError.decryptionFailed
        }
    }

    // MARK: - Vault key operations

    /// Generate a new vault key and encrypt it with the master key.
    func generateEncryptedVaultKey() throws -> Data {
        let masterKey = try getMasterKey()
        let vaultKey = CryptoEngine.generateKey()
        return try encrypt(vaultKey.data, using: masterKey)
    }

    /// Decrypt a vault key using the master key.
    func decryptVaultKey(from encryptedKey: Data) throws -> SymmetricKey {
        let masterKey = try getMasterKey()
        let vaultKeyData = try decrypt(encryptedKey, using: masterKey)
        return SymmetricKey(data: vaultKeyData)
    }

    // MARK: - Item payload operations

    /// Encrypt an `ItemPayload` with the given vault key.
    func encryptPayload(_ payload: ItemPayload, using vaultKey: SymmetricKey) throws -> Data {
        let data = try JSONEncoder().encode(payload)
        return try encrypt(data, using: vaultKey)
    }

    /// Decrypt an item's encrypted payload with the given vault key.
    func decryptPayload(from ciphertext: Data, using vaultKey: SymmetricKey) throws -> ItemPayload {
        let data = try decrypt(ciphertext, using: vaultKey)
        return try JSONDecoder().decode(ItemPayload.self, from: data)
    }

    // MARK: - Master password verification

    /// Derive a verification hash from the master key.
    /// Stored alongside the salt to verify the password on unlock.
    static func verificationHash(from masterKey: SymmetricKey) -> Data {
        let context = "1passhole-verify".data(using: .utf8)!
        let derived = HKDF<SHA256>.deriveKey(
            inputKeyMaterial: masterKey,
            info: context,
            outputByteCount: 32
        )
        return derived.withUnsafeBytes { Data($0) }
    }
}
