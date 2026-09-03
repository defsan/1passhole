import Testing
import Foundation
@testable import OnePasshole

/// Covers `OPVaultSession.derivedNativeMasterKey()` — the key that stands in for
/// 1passhole's own master password when an OPVault connection is the primary vault.
/// It must be deterministic (same OPVault password → same key every unlock) and unique
/// per vault (different OPVault key material → different key).
struct OPVaultServiceTests {
    private func makeSession(masterEnc: Data, masterMac: Data, overviewEnc: Data, overviewMac: Data) -> OPVaultSession {
        OPVaultSession(
            connectionID: UUID(),
            folderURL: URL(fileURLWithPath: "/tmp/not-a-real-vault"),
            profileDir: URL(fileURLWithPath: "/tmp/not-a-real-vault/default"),
            masterEnc: masterEnc,
            masterMac: masterMac,
            overviewEnc: overviewEnc,
            overviewMac: overviewMac
        )
    }

    @Test func derivedKeyIsDeterministic() {
        let masterEnc = Data(repeating: 0x01, count: 32)
        let masterMac = Data(repeating: 0x02, count: 32)
        let overviewEnc = Data(repeating: 0x03, count: 32)
        let overviewMac = Data(repeating: 0x04, count: 32)

        let key1 = makeSession(masterEnc: masterEnc, masterMac: masterMac, overviewEnc: overviewEnc, overviewMac: overviewMac).derivedNativeMasterKey()
        let key2 = makeSession(masterEnc: masterEnc, masterMac: masterMac, overviewEnc: overviewEnc, overviewMac: overviewMac).derivedNativeMasterKey()

        #expect(key1.data == key2.data)
        #expect(key1.data.count == 32)
    }

    @Test func derivedKeyDiffersPerVault() {
        let keyA = makeSession(
            masterEnc: Data(repeating: 0x01, count: 32),
            masterMac: Data(repeating: 0x02, count: 32),
            overviewEnc: Data(repeating: 0x03, count: 32),
            overviewMac: Data(repeating: 0x04, count: 32)
        ).derivedNativeMasterKey()

        let keyB = makeSession(
            masterEnc: Data(repeating: 0xAA, count: 32),
            masterMac: Data(repeating: 0xBB, count: 32),
            overviewEnc: Data(repeating: 0xCC, count: 32),
            overviewMac: Data(repeating: 0xDD, count: 32)
        ).derivedNativeMasterKey()

        #expect(keyA.data != keyB.data)
    }
}
