import Testing
import Foundation
import CryptoKit
@testable import OnePasshole

struct CryptoEngineTests {
    let engine = CryptoEngine()

    @Test func encryptDecryptRoundTrip() throws {
        let key = CryptoEngine.generateKey()
        let plaintext = "secret password 🔑".data(using: .utf8)!

        let ciphertext = try engine.encrypt(plaintext, using: key.symmetricKey)
        let decrypted = try engine.decrypt(ciphertext, using: key.symmetricKey)

        #expect(decrypted == plaintext)
        #expect(ciphertext != plaintext)
    }

    @Test func decryptWithWrongKeyFails() throws {
        let key1 = CryptoEngine.generateKey()
        let key2 = CryptoEngine.generateKey()
        let plaintext = "secret".data(using: .utf8)!

        let ciphertext = try engine.encrypt(plaintext, using: key1.symmetricKey)
        #expect(throws: CryptoError.self) {
            try engine.decrypt(ciphertext, using: key2.symmetricKey)
        }
    }

    @Test func payloadEncryptDecrypt() throws {
        let key = CryptoEngine.generateKey()
        let payload = ItemPayload(
            fields: [
                ItemField(label: "Username", value: "alice"),
                ItemField(label: "Password", value: "hunter2", type: .password, isConcealed: true),
            ],
            notes: "Test note"
        )

        let encrypted = try engine.encryptPayload(payload, using: key.symmetricKey)
        let decrypted = try engine.decryptPayload(from: encrypted, using: key.symmetricKey)

        #expect(decrypted.fields.count == 2)
        #expect(decrypted.fields[0].value == "alice")
        #expect(decrypted.fields[1].value == "hunter2")
        #expect(decrypted.notes == "Test note")
    }

    @Test func vaultKeyRoundTrip() throws {
        let masterKey = CryptoEngine.generateKey()
        engine.setMasterKey(masterKey)

        let encryptedVaultKey = try engine.generateEncryptedVaultKey()
        let decryptedVaultKey = try engine.decryptVaultKey(from: encryptedVaultKey)

        // Verify the vault key works for encryption
        let plaintext = "test".data(using: .utf8)!
        let ciphertext = try engine.encrypt(plaintext, using: decryptedVaultKey)
        let decrypted = try engine.decrypt(ciphertext, using: decryptedVaultKey)
        #expect(decrypted == plaintext)
    }

    @Test func verificationHashDeterministic() {
        let key = CryptoEngine.generateKey()
        let hash1 = CryptoEngine.verificationHash(from: key.symmetricKey)
        let hash2 = CryptoEngine.verificationHash(from: key.symmetricKey)
        #expect(hash1 == hash2)
    }

    @Test func verificationHashDifferentKeys() {
        let key1 = CryptoEngine.generateKey()
        let key2 = CryptoEngine.generateKey()
        let hash1 = CryptoEngine.verificationHash(from: key1.symmetricKey)
        let hash2 = CryptoEngine.verificationHash(from: key2.symmetricKey)
        #expect(hash1 != hash2)
    }

    @Test func clearKeysLocks() throws {
        let key = CryptoEngine.generateKey()
        engine.setMasterKey(key)
        #expect(engine.isUnlocked)

        engine.clearKeys()
        #expect(!engine.isUnlocked)

        #expect(throws: CryptoError.self) {
            try engine.generateEncryptedVaultKey()
        }
    }
}

struct PasswordGeneratorTests {
    @Test func randomPasswordLength() {
        let password = PasswordGenerator.random(length: 32)
        #expect(password.count == 32)
    }

    @Test func randomPasswordCharsets() {
        let digitsOnly = PasswordGenerator.random(
            length: 100,
            uppercase: false,
            lowercase: false,
            digits: true,
            symbols: false
        )
        #expect(digitsOnly.allSatisfy(\.isNumber))
    }

    @Test func passphraseWordCount() {
        let phrase = PasswordGenerator.passphrase(wordCount: 5, separator: "-")
        let words = phrase.split(separator: "-")
        #expect(words.count == 5)
    }
}
