import Testing
import Foundation
@testable import OnePasshole

/// Covers OPVault "sections" fields (e.g. an id like `"user[login]"`) — previously
/// completely invisible, since only the flat top-level `fields` array was read. This
/// verifies both directions: reading surfaces them with a sensible label while
/// remembering their exact original slot, and writing an edited value back updates only
/// that slot in place, without duplicating it into the flat array or disturbing anything
/// else in the section.
struct OPVaultSectionFieldsTests {
    private func makeSession(profileDir: URL) -> (session: OPVaultSession, itemEnc: Data, itemMac: Data) {
        let masterEnc = Data(repeating: 0x10, count: 32)
        let masterMac = Data(repeating: 0x11, count: 32)
        let overviewEnc = Data(repeating: 0x12, count: 32)
        let overviewMac = Data(repeating: 0x13, count: 32)
        let session = OPVaultSession(
            connectionID: UUID(),
            folderURL: URL(fileURLWithPath: "/tmp/not-a-real-vault"),
            profileDir: profileDir,
            masterEnc: masterEnc,
            masterMac: masterMac,
            overviewEnc: overviewEnc,
            overviewMac: overviewMac
        )
        return (session, Data(repeating: 0x20, count: 32), Data(repeating: 0x21, count: 32))
    }

    /// Writes one item directly to disk whose details JSON has a section field alongside
    /// an ordinary flat "username" field. `sectionFieldN`/`sectionFieldT` let tests cover
    /// the bracket-group text showing up in either the field's id or its title — real
    /// OPVault data isn't consistent about which one carries it.
    private func writeItemWithSectionField(
        session: OPVaultSession,
        itemEnc: Data,
        itemMac: Data,
        profileDir: URL,
        sectionFieldN: String = "user[login]",
        sectionFieldT: String = "Login"
    ) throws -> String {
        let uuid = "0AAAAAAAAAAA4A4AAAAAAAAAAAAA"

        let overviewData = try JSONEncoder().encode(OPVaultJSONValue.object(["title": .string("Example")]))
        let oBlob = OPVaultCrypto.opdata01Encrypt(plaintext: overviewData, encKey: session.overviewEnc, macKey: session.overviewMac)

        let details: OPVaultJSONValue = .object([
            "fields": .array([
                .object(["name": .string("username"), "value": .string("flat-user"), "type": .string("T"), "designation": .string("username")])
            ]),
            "notesPlain": .string(""),
            "sections": .array([
                .object([
                    "title": .string("Extra"),
                    "fields": .array([
                        .object(["n": .string(sectionFieldN), "t": .string(sectionFieldT), "v": .string("secret-login-value"), "k": .string("string")]),
                        .object(["n": .string("other"), "t": .string("Other"), "v": .string("untouched"), "k": .string("string")]),
                    ]),
                ])
            ]),
        ])
        let detailsData = try JSONEncoder().encode(details)
        let dBlob = OPVaultCrypto.opdata01Encrypt(plaintext: detailsData, encKey: itemEnc, macKey: itemMac)
        let kBlob = OPVaultCrypto.wrapItemKey(masterEnc: session.masterEnc, masterMac: session.masterMac, itemEnc: itemEnc, itemMac: itemMac)

        let item = OPVaultRawItem(
            category: "001", created: 1, updated: 1, tx: 1, fave: 0, trashed: nil,
            uuid: uuid, k: kBlob.base64EncodedString(), o: oBlob.base64EncodedString(), d: dBlob.base64EncodedString(), hmac: nil
        )
        try OPVaultFileStore.mutateBand(profileDir: profileDir, letter: "0") { band in
            band[uuid] = item
        }
        return uuid
    }

    @Test func sectionFieldIsSurfacedWithGroupedLabelAndSourceKey() throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let (session, itemEnc, itemMac) = makeSession(profileDir: tmp)
        let uuid = try writeItemWithSectionField(session: session, itemEnc: itemEnc, itemMac: itemMac, profileDir: tmp)

        let payload = try OPVaultService.decryptPayload(session: session, uuid: uuid)

        let flatField = payload.fields.first { $0.sectionSourceKey == nil }
        #expect(flatField?.value == "flat-user")

        let sectionField = payload.fields.first { $0.sectionSourceKey != nil }
        #expect(sectionField?.label == "User: Login")
    }

    /// Real OPVault data isn't consistent about which key carries the bracket text — this
    /// covers it showing up in the title ("t") rather than the id ("n"), which was the
    /// actual bug: only "n" was checked, so a bracketed title displayed completely raw.
    @Test func groupedLabelParsedWhenBracketTextIsInTitleInsteadOfID() throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let (session, itemEnc, itemMac) = makeSession(profileDir: tmp)
        let uuid = try writeItemWithSectionField(
            session: session, itemEnc: itemEnc, itemMac: itemMac, profileDir: tmp,
            sectionFieldN: "field123", sectionFieldT: "user[login]"
        )

        let payload = try OPVaultService.decryptPayload(session: session, uuid: uuid)
        let sectionField = payload.fields.first { $0.sectionSourceKey != nil }

        #expect(sectionField?.label == "User: Login")
        #expect(sectionField?.sectionSourceKey == "0.field123") // still keyed by the stable id, not the title
    }

    @Test func editingSectionFieldUpdatesOnlyItsOriginalSlot() throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let (session, itemEnc, itemMac) = makeSession(profileDir: tmp)
        let uuid = try writeItemWithSectionField(session: session, itemEnc: itemEnc, itemMac: itemMac, profileDir: tmp)

        var payload = try OPVaultService.decryptPayload(session: session, uuid: uuid)
        guard let index = payload.fields.firstIndex(where: { $0.sectionSourceKey == "0.user[login]" }) else {
            Issue.record("section field not found")
            return
        }
        payload.fields[index].value = "updated-login-value"

        try OPVaultService.updateItem(session: session, uuid: uuid, title: "Example", payload: payload)

        // Re-decrypt independently and inspect the raw details structure directly,
        // rather than only through the same mapping function being tested.
        guard let rawItem = OPVaultFileStore.findItem(profileDir: tmp, uuid: uuid),
              let dBlob = Data(base64Encoded: rawItem.d)
        else {
            Issue.record("item not found after update")
            return
        }
        let plain = try OPVaultCrypto.opdata01Decrypt(dBlob, encKey: itemEnc, macKey: itemMac)
        let details = try JSONDecoder().decode(OPVaultJSONValue.self, from: plain)
        guard let obj = details.objectValue,
              let sections = obj["sections"]?.arrayValue,
              let sectionFields = sections[0].objectValue?["fields"]?.arrayValue
        else {
            Issue.record("sections structure missing after update")
            return
        }

        let updatedField = sectionFields.first { $0.objectValue?["n"]?.stringValue == "user[login]" }
        #expect(updatedField?.objectValue?["v"]?.stringValue == "updated-login-value")
        #expect(updatedField?.objectValue?["t"]?.stringValue == "Login") // untouched

        let otherField = sectionFields.first { $0.objectValue?["n"]?.stringValue == "other" }
        #expect(otherField?.objectValue?["v"]?.stringValue == "untouched")

        // Must not have leaked into the flat top-level fields array.
        let flatFields = obj["fields"]?.arrayValue ?? []
        let leaked = flatFields.contains { $0.objectValue?["name"]?.stringValue == "user[login]" }
        #expect(!leaked)
    }

    // MARK: - TOTP fields

    /// Writes an item whose only section field is a TOTP field (id prefixed "TOTP_",
    /// matching real OPVault data — confirmed against KeePassXC's production reader).
    private func writeItemWithTOTPField(
        session: OPVaultSession,
        itemEnc: Data,
        itemMac: Data,
        profileDir: URL
    ) throws -> String {
        let uuid = "0BBBBBBBBBBB4B4BBBBBBBBBBBBB"

        let overviewData = try JSONEncoder().encode(OPVaultJSONValue.object(["title": .string("Example")]))
        let oBlob = OPVaultCrypto.opdata01Encrypt(plaintext: overviewData, encKey: session.overviewEnc, macKey: session.overviewMac)

        let details: OPVaultJSONValue = .object([
            "fields": .array([]),
            "notesPlain": .string(""),
            "sections": .array([
                .object([
                    "title": .string(""),
                    "fields": .array([
                        .object(["n": .string("TOTP_1"), "t": .string("one-time password"), "v": .string("JBSWY3DPEHPK3PXP"), "k": .string("concealed")]),
                    ]),
                ])
            ]),
        ])
        let detailsData = try JSONEncoder().encode(details)
        let dBlob = OPVaultCrypto.opdata01Encrypt(plaintext: detailsData, encKey: itemEnc, macKey: itemMac)
        let kBlob = OPVaultCrypto.wrapItemKey(masterEnc: session.masterEnc, masterMac: session.masterMac, itemEnc: itemEnc, itemMac: itemMac)

        let item = OPVaultRawItem(
            category: "001", created: 1, updated: 1, tx: 1, fave: 0, trashed: nil,
            uuid: uuid, k: kBlob.base64EncodedString(), o: oBlob.base64EncodedString(), d: dBlob.base64EncodedString(), hmac: nil
        )
        try OPVaultFileStore.mutateBand(profileDir: profileDir, letter: "0") { band in
            band[uuid] = item
        }
        return uuid
    }

    @Test func totpSectionFieldParsesAsTOTPTypeAndIsConcealed() throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let (session, itemEnc, itemMac) = makeSession(profileDir: tmp)
        let uuid = try writeItemWithTOTPField(session: session, itemEnc: itemEnc, itemMac: itemMac, profileDir: tmp)

        let payload = try OPVaultService.decryptPayload(session: session, uuid: uuid)
        let totpField = try #require(payload.fields.first { $0.type == .totp })

        #expect(totpField.value == "JBSWY3DPEHPK3PXP")
        #expect(totpField.isConcealed)
        #expect(totpField.sectionSourceKey == "0.TOTP_1")
    }

    @Test func editingTOTPFieldUpdatesOnlyItsOriginalSlot() throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let (session, itemEnc, itemMac) = makeSession(profileDir: tmp)
        let uuid = try writeItemWithTOTPField(session: session, itemEnc: itemEnc, itemMac: itemMac, profileDir: tmp)

        var payload = try OPVaultService.decryptPayload(session: session, uuid: uuid)
        guard let index = payload.fields.firstIndex(where: { $0.type == .totp }) else {
            Issue.record("totp field not found")
            return
        }
        payload.fields[index].value = "otpauth://totp/Example?secret=KRSXG5CTMVRXEZLU&digits=6&period=30"

        try OPVaultService.updateItem(session: session, uuid: uuid, title: "Example", payload: payload)

        let reloaded = try OPVaultService.decryptPayload(session: session, uuid: uuid)
        let totpField = try #require(reloaded.fields.first { $0.type == .totp })
        #expect(totpField.value == "otpauth://totp/Example?secret=KRSXG5CTMVRXEZLU&digits=6&period=30")
        #expect(totpField.sectionSourceKey == "0.TOTP_1")
    }

    @Test func addingNewTOTPFieldCreatesDefaultSectionWithTOTPPrefixedID() throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let (session, itemEnc, itemMac) = makeSession(profileDir: tmp)

        // Item with no sections at all yet — the "add a TOTP field to a plain login" case.
        let uuid = "0CCCCCCCCCCC4C4CCCCCCCCCCCCC"
        let overviewData = try JSONEncoder().encode(OPVaultJSONValue.object(["title": .string("Example")]))
        let oBlob = OPVaultCrypto.opdata01Encrypt(plaintext: overviewData, encKey: session.overviewEnc, macKey: session.overviewMac)
        let details: OPVaultJSONValue = .object([
            "fields": .array([
                .object(["name": .string("username"), "value": .string("flat-user"), "type": .string("T"), "designation": .string("username")])
            ]),
            "notesPlain": .string(""),
        ])
        let detailsData = try JSONEncoder().encode(details)
        let dBlob = OPVaultCrypto.opdata01Encrypt(plaintext: detailsData, encKey: itemEnc, macKey: itemMac)
        let kBlob = OPVaultCrypto.wrapItemKey(masterEnc: session.masterEnc, masterMac: session.masterMac, itemEnc: itemEnc, itemMac: itemMac)
        let item = OPVaultRawItem(
            category: "001", created: 1, updated: 1, tx: 1, fave: 0, trashed: nil,
            uuid: uuid, k: kBlob.base64EncodedString(), o: oBlob.base64EncodedString(), d: dBlob.base64EncodedString(), hmac: nil
        )
        try OPVaultFileStore.mutateBand(profileDir: tmp, letter: "0") { band in
            band[uuid] = item
        }

        var payload = try OPVaultService.decryptPayload(session: session, uuid: uuid)
        payload.fields.append(ItemField(label: "One-Time Password", value: "JBSWY3DPEHPK3PXP", type: .totp, isConcealed: true))
        try OPVaultService.updateItem(session: session, uuid: uuid, title: "Example", payload: payload)

        guard let rawItem = OPVaultFileStore.findItem(profileDir: tmp, uuid: uuid),
              let dBlobAfter = Data(base64Encoded: rawItem.d)
        else {
            Issue.record("item not found after update")
            return
        }
        let plain = try OPVaultCrypto.opdata01Decrypt(dBlobAfter, encKey: itemEnc, macKey: itemMac)
        let decoded = try JSONDecoder().decode(OPVaultJSONValue.self, from: plain)
        guard let obj = decoded.objectValue,
              let sections = obj["sections"]?.arrayValue,
              let sectionFields = sections.first?.objectValue?["fields"]?.arrayValue
        else {
            Issue.record("no sections created for new TOTP field")
            return
        }

        let totpEntry = sectionFields.first { $0.objectValue?["n"]?.stringValue?.hasPrefix("TOTP_") == true }
        #expect(totpEntry?.objectValue?["v"]?.stringValue == "JBSWY3DPEHPK3PXP")

        // Must not have leaked into the flat top-level fields array.
        let flatFields = obj["fields"]?.arrayValue ?? []
        let leaked = flatFields.contains { $0.objectValue?["value"]?.stringValue == "JBSWY3DPEHPK3PXP" }
        #expect(!leaked)

        // Re-reading through the normal service path surfaces it as a proper .totp field.
        let reloaded = try OPVaultService.decryptPayload(session: session, uuid: uuid)
        #expect(reloaded.fields.contains { $0.type == .totp && $0.value == "JBSWY3DPEHPK3PXP" })
    }
}
