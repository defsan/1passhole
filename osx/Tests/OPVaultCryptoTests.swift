import Testing
import Foundation
import CryptoKit
@testable import OnePasshole

/// Swift-side equivalent of `python3 scripts/opvault_tool.py selftest`: proves the
/// ported opdata01/PBKDF2/item-key/hmac algorithm is internally correct, using only
/// synthetic data — no real vault or real password involved.
struct OPVaultCryptoTests {
    @Test func opdata01RoundTrip() throws {
        let encKey = randomBytes(32)
        let macKey = randomBytes(32)
        let plaintext = Data("hello opvault 🔐".utf8)

        let blob = OPVaultCrypto.opdata01Encrypt(plaintext: plaintext, encKey: encKey, macKey: macKey)
        let decrypted = try OPVaultCrypto.opdata01Decrypt(blob, encKey: encKey, macKey: macKey)

        #expect(decrypted == plaintext)
    }

    @Test func opdata01RoundTripEmptyPlaintext() throws {
        let encKey = randomBytes(32)
        let macKey = randomBytes(32)
        let blob = OPVaultCrypto.opdata01Encrypt(plaintext: Data(), encKey: encKey, macKey: macKey)
        let decrypted = try OPVaultCrypto.opdata01Decrypt(blob, encKey: encKey, macKey: macKey)
        #expect(decrypted.isEmpty)
    }

    @Test func opdata01WrongKeyFails() throws {
        let encKey = randomBytes(32)
        let macKey = randomBytes(32)
        let wrongMacKey = randomBytes(32)
        let blob = OPVaultCrypto.opdata01Encrypt(plaintext: Data("secret".utf8), encKey: encKey, macKey: macKey)

        #expect(throws: OPVaultError.self) {
            try OPVaultCrypto.opdata01Decrypt(blob, encKey: encKey, macKey: wrongMacKey)
        }
    }

    @Test func opdata01TamperedCiphertextDetected() throws {
        let encKey = randomBytes(32)
        let macKey = randomBytes(32)
        var blob = OPVaultCrypto.opdata01Encrypt(plaintext: Data("secret".utf8), encKey: encKey, macKey: macKey)
        blob[40] ^= 0xFF // flip a byte inside the ciphertext region

        #expect(throws: OPVaultError.self) {
            try OPVaultCrypto.opdata01Decrypt(blob, encKey: encKey, macKey: macKey)
        }
    }

    @Test func pbkdf2Deterministic() {
        let password = Data("correct horse battery staple".utf8)
        let salt = randomBytes(16)
        let a = OPVaultCrypto.pbkdf2SHA512(password: password, salt: salt, iterations: 500)
        let b = OPVaultCrypto.pbkdf2SHA512(password: password, salt: salt, iterations: 500)
        #expect(a == b)
        #expect(a.count == 64)
    }

    @Test func pbkdf2DifferentPasswordsDiffer() {
        let salt = randomBytes(16)
        let a = OPVaultCrypto.pbkdf2SHA512(password: Data("password one".utf8), salt: salt, iterations: 500)
        let b = OPVaultCrypto.pbkdf2SHA512(password: Data("password two".utf8), salt: salt, iterations: 500)
        #expect(a != b)
    }

    @Test func itemKeyWrapRoundTrip() throws {
        let masterEnc = randomBytes(32)
        let masterMac = randomBytes(32)
        let itemEnc = randomBytes(32)
        let itemMac = randomBytes(32)

        let wrapped = OPVaultCrypto.wrapItemKey(masterEnc: masterEnc, masterMac: masterMac, itemEnc: itemEnc, itemMac: itemMac)
        let unwrapped = try OPVaultCrypto.unwrapItemKey(masterEnc: masterEnc, masterMac: masterMac, blob: wrapped)

        #expect(unwrapped.enc == itemEnc)
        #expect(unwrapped.mac == itemMac)
    }

    @Test func itemKeyUnwrapWrongMasterFails() throws {
        let masterEnc = randomBytes(32)
        let masterMac = randomBytes(32)
        let wrapped = OPVaultCrypto.wrapItemKey(masterEnc: masterEnc, masterMac: masterMac, itemEnc: randomBytes(32), itemMac: randomBytes(32))

        #expect(throws: OPVaultError.self) {
            try OPVaultCrypto.unwrapItemKey(masterEnc: masterEnc, masterMac: randomBytes(32), blob: wrapped)
        }
    }

    @Test func hmacFormulaDeterministicAndSensitive() {
        let overviewMac = randomBytes(32)
        var fields: [String: String] = [
            "category": "001",
            "created": "1700000000",
            "updated": "1700000000",
            "tx": "1700000000",
            "fave": "0",
            "uuid": "0D75801F8C844D8BB77CA7FFF12D92A3",
            "k": "base64k==",
            "o": "base64o==",
            "d": "base64d==",
        ]

        let hmac1 = OPVaultCrypto.computeItemHMAC(sortedFieldsExcludingHMAC: fields, overviewMac: overviewMac)
        let hmac2 = OPVaultCrypto.computeItemHMAC(sortedFieldsExcludingHMAC: fields, overviewMac: overviewMac)
        #expect(hmac1 == hmac2) // deterministic

        fields["updated"] = "1700000001"
        let hmac3 = OPVaultCrypto.computeItemHMAC(sortedFieldsExcludingHMAC: fields, overviewMac: overviewMac)
        #expect(hmac1 != hmac3) // sensitive to any field change
    }

    /// End-to-end: build a synthetic profile + one item entirely with OPVaultCrypto
    /// primitives (mirroring build_synthetic_vault/VaultSession in the Python tool),
    /// then unlock and decrypt it back, proving the full key hierarchy is correct.
    @Test func syntheticVaultEndToEnd() throws {
        let password = Data("correct horse battery staple".utf8)
        let salt = randomBytes(16)
        let iterations = 500

        // Profile-level unlock: PBKDF2 output split directly into enc/mac (no extra hash here).
        let derived = OPVaultCrypto.pbkdf2SHA512(password: password, salt: salt, iterations: iterations)
        let profileEncKey = derived.prefix(32)
        let profileMacKey = derived.suffix(32)

        // Arbitrary 64-byte "master key material" / "overview key material", wrapped the
        // way profile.masterKey/profile.overviewKey are.
        let masterKeyPlain = randomBytes(64)
        let overviewKeyPlain = randomBytes(64)
        let masterKeyBlob = OPVaultCrypto.opdata01Encrypt(plaintext: masterKeyPlain, encKey: Data(profileEncKey), macKey: Data(profileMacKey))
        let overviewKeyBlob = OPVaultCrypto.opdata01Encrypt(plaintext: overviewKeyPlain, encKey: Data(profileEncKey), macKey: Data(profileMacKey))

        // Unlock: decrypt those blobs, then SHA-512-split each into enc/mac (the step
        // that was missing in the first implementation attempt).
        let decryptedMasterKey = try OPVaultCrypto.opdata01Decrypt(masterKeyBlob, encKey: Data(profileEncKey), macKey: Data(profileMacKey))
        let decryptedOverviewKey = try OPVaultCrypto.opdata01Decrypt(overviewKeyBlob, encKey: Data(profileEncKey), macKey: Data(profileMacKey))
        #expect(decryptedMasterKey == masterKeyPlain)
        #expect(decryptedOverviewKey == overviewKeyPlain)

        let (masterEnc, masterMac) = OPVaultCrypto.deriveEncMacKeys(fromDecryptedProfileKey: decryptedMasterKey)
        let (overviewEnc, overviewMac) = OPVaultCrypto.deriveEncMacKeys(fromDecryptedProfileKey: decryptedOverviewKey)

        // Create one item.
        let itemEnc = randomBytes(32)
        let itemMac = randomBytes(32)
        let overview = ["title": "Example Login"]
        let details = ["password": "hunter2", "notesPlain": "test note"]
        let overviewJSON = try JSONSerialization.data(withJSONObject: overview)
        let detailsJSON = try JSONSerialization.data(withJSONObject: details)

        let oBlob = OPVaultCrypto.opdata01Encrypt(plaintext: overviewJSON, encKey: overviewEnc, macKey: overviewMac)
        let dBlob = OPVaultCrypto.opdata01Encrypt(plaintext: detailsJSON, encKey: itemEnc, macKey: itemMac)
        let kBlob = OPVaultCrypto.wrapItemKey(masterEnc: masterEnc, masterMac: masterMac, itemEnc: itemEnc, itemMac: itemMac)

        var fields: [String: String] = [
            "category": "001",
            "created": "1700000000",
            "updated": "1700000000",
            "tx": "1700000000",
            "fave": "0",
            "uuid": "0D75801F8C844D8BB77CA7FFF12D92A3",
            "k": kBlob.base64EncodedString(),
            "o": oBlob.base64EncodedString(),
            "d": dBlob.base64EncodedString(),
        ]
        let hmac = OPVaultCrypto.computeItemHMAC(sortedFieldsExcludingHMAC: fields, overviewMac: overviewMac)
        fields["hmac"] = hmac.base64EncodedString()

        // Fresh "session": re-derive everything from the password again and decrypt.
        let reDerived = OPVaultCrypto.pbkdf2SHA512(password: password, salt: salt, iterations: iterations)
        let reMasterKeyBlob = try OPVaultCrypto.opdata01Decrypt(masterKeyBlob, encKey: Data(reDerived.prefix(32)), macKey: Data(reDerived.suffix(32)))
        let reOverviewKeyBlob = try OPVaultCrypto.opdata01Decrypt(overviewKeyBlob, encKey: Data(reDerived.prefix(32)), macKey: Data(reDerived.suffix(32)))
        let (reMasterEnc, reMasterMac) = OPVaultCrypto.deriveEncMacKeys(fromDecryptedProfileKey: reMasterKeyBlob)
        let (reOverviewEnc, reOverviewMac) = OPVaultCrypto.deriveEncMacKeys(fromDecryptedProfileKey: reOverviewKeyBlob)

        let reOBlob = Data(base64Encoded: fields["o"]!)!
        let reKBlob = Data(base64Encoded: fields["k"]!)!
        let reDBlob = Data(base64Encoded: fields["d"]!)!

        let reOverviewJSON = try OPVaultCrypto.opdata01Decrypt(reOBlob, encKey: reOverviewEnc, macKey: reOverviewMac)
        let (reItemEnc, reItemMac) = try OPVaultCrypto.unwrapItemKey(masterEnc: reMasterEnc, masterMac: reMasterMac, blob: reKBlob)
        let reDetailsJSON = try OPVaultCrypto.opdata01Decrypt(reDBlob, encKey: reItemEnc, macKey: reItemMac)

        #expect(reOverviewJSON == overviewJSON)
        #expect(reDetailsJSON == detailsJSON)

        // hmac recomputed from the current fields must match what was stored.
        var fieldsWithoutHMAC = fields
        fieldsWithoutHMAC.removeValue(forKey: "hmac")
        let recomputedHMAC = OPVaultCrypto.computeItemHMAC(sortedFieldsExcludingHMAC: fieldsWithoutHMAC, overviewMac: reOverviewMac)
        #expect(recomputedHMAC.base64EncodedString() == fields["hmac"])

        // Wrong password must fail at the very first step.
        let wrongDerived = OPVaultCrypto.pbkdf2SHA512(password: Data("wrong password".utf8), salt: salt, iterations: iterations)
        #expect(throws: OPVaultError.self) {
            try OPVaultCrypto.opdata01Decrypt(masterKeyBlob, encKey: Data(wrongDerived.prefix(32)), macKey: Data(wrongDerived.suffix(32)))
        }
    }
}

private func randomBytes(_ count: Int) -> Data {
    var data = Data(count: count)
    _ = data.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, count, $0.baseAddress!) }
    return data
}
