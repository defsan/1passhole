import Foundation
import CryptoKit
import Argon2Swift

enum KeyDerivation {
    struct DerivedResult {
        let key: SymmetricKeyData
        let salt: Data
    }

    /// Derive a 256-bit master key from a password using Argon2id.
    ///
    /// Parameters tuned for desktop use:
    ///   - 64 MB memory
    ///   - 3 iterations
    ///   - 4 parallelism lanes
    static func deriveKey(
        from password: String,
        salt: Data? = nil
    ) throws -> DerivedResult {
        let saltData: Data
        if let salt {
            saltData = salt
        } else {
            var bytes = [UInt8](repeating: 0, count: 32)
            guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
                throw CryptoError.keyDerivationFailed
            }
            saltData = Data(bytes)
        }

        let passwordData = Data(password.utf8)

        let result = try Argon2Swift.hashPasswordBytes(
            password: passwordData,
            salt: Salt(bytes: saltData),
            iterations: 3,
            memory: 65536, // 64 MB
            parallelism: 4,
            length: 32,
            type: .id
        )

        let hashData = result.hashData()

        return DerivedResult(
            key: SymmetricKeyData(data: hashData),
            salt: saltData
        )
    }
}
