import Foundation
import Security
import LocalAuthentication

/// What a Touch ID unlock restores: 1passhole's master key plus the unlocked keys of
/// each connected OPVault (keyed by connection id), so one biometric unlock opens
/// everything — the same reach as typing the master password. No password is stored.
struct BiometricUnlockBundle: Codable, Sendable {
    let masterKey: Data
    let opvaultKeys: [String: OPVaultKeys]

    func opvaultKeys(for connectionID: UUID) -> OPVaultKeys? {
        opvaultKeys[connectionID.uuidString]
    }
}

/// Manages master password setup, verification, and Touch ID enrollment.
///
/// Stores in Keychain:
///   - `salt`: the Argon2id salt used to derive the master key
///   - `verificationHash`: HKDF-derived hash to verify the password without storing it
///   - `biometricAccount`: a `BiometricUnlockBundle`, protected by Touch ID
final class AuthService: @unchecked Sendable {
    private let crypto: CryptoEngine

    private let keychainService = "com.1passhole.auth"
    private let saltAccount = "master-salt"
    private let hashAccount = "master-hash"
    private let biometricAccount = "master-key-biometric"

    init(cryptoEngine: CryptoEngine) {
        self.crypto = cryptoEngine
    }

    // MARK: - Setup state

    var isSetUp: Bool {
        keychainRead(account: saltAccount) != nil
    }

    // MARK: - Master password setup

    func setup(password: String) throws -> SymmetricKeyData {
        let derived = try KeyDerivation.deriveKey(from: password)

        let verificationHash = CryptoEngine.verificationHash(from: derived.key.symmetricKey)

        try keychainWrite(data: derived.salt, account: saltAccount)
        try keychainWrite(data: verificationHash, account: hashAccount)

        return derived.key
    }

    // MARK: - Master password unlock

    func unlock(password: String) throws -> SymmetricKeyData {
        guard let salt = keychainRead(account: saltAccount),
              let storedHash = keychainRead(account: hashAccount) else {
            throw AuthError.notSetUp
        }

        let derived = try KeyDerivation.deriveKey(from: password, salt: salt)
        let verificationHash = CryptoEngine.verificationHash(from: derived.key.symmetricKey)

        guard verificationHash == storedHash else {
            throw AuthError.wrongPassword
        }

        return derived.key
    }

    // MARK: - Touch ID

    var isTouchIDAvailable: Bool {
        let context = LAContext()
        var error: NSError?
        return context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &error)
    }

    var isTouchIDEnrolled: Bool {
        keychainRead(account: biometricAccount) != nil
    }

    func enrollTouchID(masterKey: SymmetricKeyData, opvaultKeys: [UUID: OPVaultKeys] = [:]) throws {
        let bundle = BiometricUnlockBundle(
            masterKey: masterKey.data,
            opvaultKeys: Dictionary(uniqueKeysWithValues: opvaultKeys.map { ($0.key.uuidString, $0.value) })
        )
        guard let payload = try? JSONEncoder().encode(bundle) else {
            throw AuthError.touchIDEnrollmentFailed
        }

        let access = SecAccessControlCreateWithFlags(
            nil,
            kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
            .biometryCurrentSet,
            nil
        )
        guard let access else { throw AuthError.touchIDEnrollmentFailed }

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: biometricAccount,
            kSecValueData as String: payload,
            kSecAttrAccessControl as String: access,
        ]

        SecItemDelete(query as CFDictionary)
        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw AuthError.touchIDEnrollmentFailed
        }
    }

    func unenrollTouchID() throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: biometricAccount,
        ]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw AuthError.keychainWriteFailed
        }
    }

    nonisolated func unlockWithTouchID() async throws -> BiometricUnlockBundle {
        let service = keychainService
        let account = biometricAccount

        let context = LAContext()
        context.localizedReason = "Unlock 1passhole"

        let query: NSDictionary = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account,
            kSecReturnData: true,
            kSecUseAuthenticationContext: context,
        ]

        var result: AnyObject?
        let status = SecItemCopyMatching(query, &result)
        guard status == errSecSuccess, let data = result as? Data else {
            throw AuthError.touchIDFailed
        }
        if let bundle = try? JSONDecoder().decode(BiometricUnlockBundle.self, from: data) {
            return bundle
        }
        // Enrolled before OPVault keys were stored: the item is just the raw master key.
        return BiometricUnlockBundle(masterKey: data, opvaultKeys: [:])
    }

    // MARK: - Change password

    /// Salt + verification hash for a master password. Changing the password means
    /// deriving a new set, re-wrapping every vault key (see `AppState.changeMasterPassword`),
    /// then storing the new set — with the old one kept to restore if the re-wrap fails.
    struct Credentials {
        let salt: Data
        let verificationHash: Data
    }

    func currentCredentials() -> Credentials? {
        guard let salt = keychainRead(account: saltAccount),
              let hash = keychainRead(account: hashAccount) else { return nil }
        return Credentials(salt: salt, verificationHash: hash)
    }

    func deriveCredentials(password: String) throws -> (key: SymmetricKeyData, credentials: Credentials) {
        let derived = try KeyDerivation.deriveKey(from: password)
        let hash = CryptoEngine.verificationHash(from: derived.key.symmetricKey)
        return (derived.key, Credentials(salt: derived.salt, verificationHash: hash))
    }

    func storeCredentials(_ credentials: Credentials) throws {
        try keychainWrite(data: credentials.salt, account: saltAccount)
        try keychainWrite(data: credentials.verificationHash, account: hashAccount)
    }

    // MARK: - Keychain helpers

    private func keychainWrite(data: Data, account: String) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)

        var addQuery = query
        addQuery[kSecValueData as String] = data
        let status = SecItemAdd(addQuery as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw AuthError.keychainWriteFailed
        }
    }

    private func keychainRead(account: String) -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess else { return nil }
        return result as? Data
    }
}

enum AuthError: LocalizedError {
    case notSetUp
    case wrongPassword
    case keychainWriteFailed
    case touchIDEnrollmentFailed
    case touchIDFailed
    case touchIDNotAvailable

    var errorDescription: String? {
        switch self {
        case .notSetUp: "No master password configured. Please set up 1passhole first."
        case .wrongPassword: "Incorrect master password."
        case .keychainWriteFailed: "Failed to save to Keychain."
        case .touchIDEnrollmentFailed: "Failed to enroll Touch ID."
        case .touchIDFailed: "Touch ID authentication failed."
        case .touchIDNotAvailable: "Touch ID is not available on this device."
        }
    }
}
