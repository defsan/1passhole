import Testing
import Foundation
@testable import OnePasshole

/// The Touch ID Keychain item now holds a `BiometricUnlockBundle` (master key + OPVault
/// keys). It must round-trip, and look up OPVault keys by connection id.
struct BiometricUnlockBundleTests {
    private let keys = OPVaultKeys(
        masterEnc: Data(repeating: 0x01, count: 32),
        masterMac: Data(repeating: 0x02, count: 32),
        overviewEnc: Data(repeating: 0x03, count: 32),
        overviewMac: Data(repeating: 0x04, count: 32)
    )

    @Test func roundTripsThroughJSON() throws {
        let connectionID = UUID()
        let bundle = BiometricUnlockBundle(
            masterKey: Data(repeating: 0xAB, count: 32),
            opvaultKeys: [connectionID.uuidString: keys]
        )
        let decoded = try JSONDecoder().decode(BiometricUnlockBundle.self, from: JSONEncoder().encode(bundle))

        #expect(decoded.masterKey == bundle.masterKey)
        #expect(decoded.opvaultKeys(for: connectionID) == keys)
        #expect(decoded.opvaultKeys(for: UUID()) == nil)
    }

    @Test func legacyRawKeyIsNotMistakenForBundle() {
        // Items enrolled before this change hold the raw 32-byte master key; decoding
        // must fail so `unlockWithTouchID` falls back to treating it as the key.
        let raw = Data(repeating: 0x7F, count: 32)
        #expect((try? JSONDecoder().decode(BiometricUnlockBundle.self, from: raw)) == nil)
    }

    @Test func sessionExposesItsKeys() {
        let session = OPVaultSession(
            connectionID: UUID(),
            folderURL: URL(fileURLWithPath: "/tmp/not-a-real-vault"),
            profileDir: URL(fileURLWithPath: "/tmp/not-a-real-vault/default"),
            masterEnc: keys.masterEnc,
            masterMac: keys.masterMac,
            overviewEnc: keys.overviewEnc,
            overviewMac: keys.overviewMac
        )
        #expect(session.keys == keys)
    }
}
