import Foundation
import Security
import LocalAuthentication

/// Manages master password setup, verification, and Touch ID enrollment.
///
/// Stores in Keychain:
///   - `salt`: the Argon2id salt used to derive the master key
///   - `verificationHash`: HKDF-derived hash to verify the password without storing it
///   - `masterKeyRef`: master key stored in Secure Enclave, protected by Touch ID
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

    func enrollTouchID(masterKey: SymmetricKeyData) throws {
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
            kSecValueData as String: masterKey.data,
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

    nonisolated func unlockWithTouchID() async throws -> SymmetricKeyData {
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
        return SymmetricKeyData(data: data)
    }

    // MARK: - Change password

    func changePassword(from oldPassword: String, to newPassword: String) throws -> SymmetricKeyData {
        let oldKey = try unlock(password: oldPassword)

        crypto.setMasterKey(oldKey)

        let newDerived = try KeyDerivation.deriveKey(from: newPassword)
        let newHash = CryptoEngine.verificationHash(from: newDerived.key.symmetricKey)

        try keychainWrite(data: newDerived.salt, account: saltAccount)
        try keychainWrite(data: newHash, account: hashAccount)

        return newDerived.key
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
