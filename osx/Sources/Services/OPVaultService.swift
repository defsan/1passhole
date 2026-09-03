import Foundation
import CryptoKit

enum OPVaultServiceError: LocalizedError {
    case wrongPassword
    case cannotAccessFolder
    case itemNotFound

    var errorDescription: String? {
        switch self {
        case .wrongPassword: "Wrong master password (or corrupt vault)"
        case .cannotAccessFolder: "Could not access the vault folder — try reconnecting it"
        case .itemNotFound: "Item not found"
        }
    }
}

/// Holds the keys derived on unlock, in memory only, for as long as this OPVault
/// connection stays unlocked. Never persisted. The security-scoped resource access is
/// tied to this object's lifetime: releasing the last reference (locking, or removing
/// the connection from `AppState.opvaultSessions`) calls `stopAccessingSecurityScopedResource`.
final class OPVaultSession {
    let connectionID: UUID
    let folderURL: URL
    let profileDir: URL
    let masterEnc: Data
    let masterMac: Data
    let overviewEnc: Data
    let overviewMac: Data

    init(connectionID: UUID, folderURL: URL, profileDir: URL, masterEnc: Data, masterMac: Data, overviewEnc: Data, overviewMac: Data) {
        self.connectionID = connectionID
        self.folderURL = folderURL
        self.profileDir = profileDir
        self.masterEnc = masterEnc
        self.masterMac = masterMac
        self.overviewEnc = overviewEnc
        self.overviewMac = overviewMac
    }

    /// A deterministic key usable as 1passhole's own `CryptoEngine` master key, derived
    /// from this session's already-unlocked OPVault key material via HKDF. When an
    /// OPVault connection is the app's primary vault (set up with no separate native
    /// password), this key stands in for one — so unlocking 1passhole and unlocking the
    /// OPVault are the same action with the same password, not two independent secrets.
    /// Re-deriving this from the same OPVault password always yields the same bytes.
    func derivedNativeMasterKey() -> SymmetricKeyData {
        let combined = masterEnc + masterMac + overviewEnc + overviewMac
        let derived = HKDF<SHA256>.deriveKey(
            inputKeyMaterial: SymmetricKey(data: combined),
            info: Data("1passhole-opvault-primary".utf8),
            outputByteCount: 32
        )
        return SymmetricKeyData(key: derived)
    }

    deinit {
        folderURL.stopAccessingSecurityScopedResource()
    }
}

private struct OPVaultOverview: Codable {
    var title: String?
    var url: String?
}

/// The "VaultService equivalent" for a live OPVault backend: unlock, list, decrypt,
/// create, update, and soft-delete items directly against the on-disk bundle.
enum OPVaultService {
    // MARK: - Unlock

    static func unlock(connection: OPVaultConnection, password: String) throws -> OPVaultSession {
        let (url, _) = try OPVaultLocator.resolveBookmark(connection.bookmarkData)
        guard url.startAccessingSecurityScopedResource() else {
            throw OPVaultServiceError.cannotAccessFolder
        }

        let profileDir = url.appendingPathComponent(connection.profileName)
        do {
            let profile = try OPVaultFileStore.loadProfile(profileDir: profileDir)
            guard let salt = Data(base64Encoded: profile.salt),
                  let masterKeyBlob = Data(base64Encoded: profile.masterKey),
                  let overviewKeyBlob = Data(base64Encoded: profile.overviewKey)
            else {
                throw OPVaultServiceError.wrongPassword
            }

            let derived = OPVaultCrypto.pbkdf2SHA512(password: Data(password.utf8), salt: salt, iterations: profile.iterations)
            let profileEnc = Data(derived.prefix(32))
            let profileMac = Data(derived.suffix(32))

            let decryptedMaster: Data
            let decryptedOverview: Data
            do {
                decryptedMaster = try OPVaultCrypto.opdata01Decrypt(masterKeyBlob, encKey: profileEnc, macKey: profileMac)
                decryptedOverview = try OPVaultCrypto.opdata01Decrypt(overviewKeyBlob, encKey: profileEnc, macKey: profileMac)
            } catch {
                throw OPVaultServiceError.wrongPassword
            }

            let (masterEnc, masterMac) = OPVaultCrypto.deriveEncMacKeys(fromDecryptedProfileKey: decryptedMaster)
            let (overviewEnc, overviewMac) = OPVaultCrypto.deriveEncMacKeys(fromDecryptedProfileKey: decryptedOverview)

            return OPVaultSession(
                connectionID: connection.id,
                folderURL: url,
                profileDir: profileDir,
                masterEnc: masterEnc,
                masterMac: masterMac,
                overviewEnc: overviewEnc,
                overviewMac: overviewMac
            )
        } catch {
            url.stopAccessingSecurityScopedResource()
            throw error
        }
    }

    // MARK: - List / decrypt

    static func listItems(session: OPVaultSession, includeTrashed: Bool = false) -> [OPVaultItemSummary] {
        OPVaultFileStore.iterItems(profileDir: session.profileDir).compactMap { _, item in
            guard includeTrashed || !(item.trashed ?? false) else { return nil }
            guard let blob = Data(base64Encoded: item.o),
                  let plain = try? OPVaultCrypto.opdata01Decrypt(blob, encKey: session.overviewEnc, macKey: session.overviewMac),
                  let overview = try? JSONDecoder().decode(OPVaultOverview.self, from: plain)
            else { return nil }

            return OPVaultItemSummary(
                uuid: item.uuid,
                category: item.category,
                title: overview.title?.isEmpty == false ? overview.title! : "Untitled",
                url: overview.url,
                trashed: item.trashed ?? false,
                modifiedAt: Date(timeIntervalSince1970: TimeInterval(item.updated))
            )
        }
    }

    static func decryptPayload(session: OPVaultSession, uuid: String) throws -> ItemPayload {
        guard let item = OPVaultFileStore.findItem(profileDir: session.profileDir, uuid: uuid) else {
            throw OPVaultServiceError.itemNotFound
        }
        guard let kBlob = Data(base64Encoded: item.k) else { throw OPVaultServiceError.itemNotFound }
        let (itemEnc, itemMac) = try OPVaultCrypto.unwrapItemKey(masterEnc: session.masterEnc, masterMac: session.masterMac, blob: kBlob)

        guard let dBlob = Data(base64Encoded: item.d) else { throw OPVaultServiceError.itemNotFound }
        let plain = try OPVaultCrypto.opdata01Decrypt(dBlob, encKey: itemEnc, macKey: itemMac)
        let details = try JSONDecoder().decode(OPVaultJSONValue.self, from: plain)
        return itemPayload(from: details)
    }

    private static func itemPayload(from details: OPVaultJSONValue) -> ItemPayload {
        guard let obj = details.objectValue else { return ItemPayload(fields: [], notes: nil) }

        var fields: [ItemField] = []
        if let rawFields = obj["fields"]?.arrayValue {
            for raw in rawFields {
                guard let fieldObj = raw.objectValue else { continue }
                let designation = fieldObj["designation"]?.stringValue ?? ""
                let name = fieldObj["name"]?.stringValue ?? designation
                let value = fieldObj["value"]?.stringValue ?? ""
                let typeCode = fieldObj["type"]?.stringValue ?? "T"
                let isPassword = designation == "password" || typeCode == "P"
                fields.append(ItemField(
                    label: name.isEmpty ? "Field" : name,
                    value: value,
                    type: isPassword ? .password : .text,
                    isConcealed: isPassword
                ))
            }
        }

        // Section fields (identity/credit-card/custom items, etc.) aren't in the flat
        // `fields` array at all — without this they're simply invisible. Nested names
        // like `user[login]` are stored as-is on `label` so the UI can group them, while
        // the exact original section index + field id is always kept in `sectionSourceKey`
        // so an edit writes back into that same slot.
        if let sections = obj["sections"]?.arrayValue {
            for (sectionIndex, section) in sections.enumerated() {
                guard let sectionObj = section.objectValue,
                      let sectionFields = sectionObj["fields"]?.arrayValue
                else { continue }

                for fieldValue in sectionFields {
                    guard let fieldObj = fieldValue.objectValue,
                          let n = fieldObj["n"]?.stringValue
                    else { continue }
                    let rawValue = fieldObj["v"]?.stringValue ?? ""
                    guard !rawValue.isEmpty else { continue }

                    // TOTP fields are identified purely by id prefix, ahead of everything
                    // else — confirmed against KeePassXC's own production OPVault reader,
                    // which checks this before its generic kind-based mapping.
                    if n.hasPrefix("TOTP_") {
                        fields.append(ItemField(
                            label: "One-Time Password",
                            value: rawValue,
                            type: .totp,
                            isConcealed: true,
                            sectionSourceKey: "\(sectionIndex).\(n)"
                        ))
                        continue
                    }

                    let kind = fieldObj["k"]?.stringValue ?? "string"
                    let title = fieldObj["t"]?.stringValue
                    // The nested path (e.g. "user[login]") can show up in either the
                    // field's id ("n") or its human title ("t") depending on the client
                    // that wrote it. Prefer a parseable path so the UI can group it;
                    // otherwise the human title. Never rewrite the stored name.
                    let label = nestedFieldLabel(candidates: [title, n].compactMap { $0 }, fallback: n)
                    fields.append(ItemField(
                        label: label,
                        value: rawValue,
                        type: fieldType(forSectionKind: kind),
                        isConcealed: kind == "concealed",
                        sectionSourceKey: "\(sectionIndex).\(n)"
                    ))
                }
            }
        }

        // Category-005 "Password" items (a bare secret with no username) store their
        // value directly as a top-level `password` string, not in `fields` or `sections`
        // at all — without this fallback those items decrypt to an empty field list and
        // render as blank. Only synthesize it when no password field was already found,
        // so this never duplicates one that came through the normal paths above.
        if !fields.contains(where: { $0.type == .password }),
           let password = obj["password"]?.stringValue, !password.isEmpty {
            fields.insert(ItemField(label: "password", value: password, type: .password, isConcealed: true), at: 0)
        }

        let notes = obj["notesPlain"]?.stringValue
        return ItemPayload(fields: fields, notes: (notes?.isEmpty ?? true) ? nil : notes)
    }

    /// Picks the string the UI should keep as `ItemField.label`. A nested path is
    /// preferred (so grouping works) over a human title; `fallback` is the field id.
    private static func nestedFieldLabel(candidates: [String], fallback: String) -> String {
        let nonempty = candidates.filter { !$0.isEmpty }
        if let path = nonempty.first(where: { FieldPath.parse($0) != nil }) {
            return path
        }
        return nonempty.first ?? fallback
    }

    private static func fieldType(forSectionKind kind: String) -> FieldType {
        switch kind {
        case "concealed": .password
        case "email": .email
        case "URL": .url
        case "phone": .phone
        case "date", "monthYear": .date
        case "cctype": .creditCardNumber
        default: .text
        }
    }

    /// Builds the details JSON to write, from a display `ItemPayload`. When `existing` is
    /// provided (editing an item), every key besides `fields`/`notesPlain`/`password` is
    /// carried over untouched — so sections/passwordHistory/etc. from a richer item
    /// created by another client are never dropped just because 1Passhole edited it.
    private static func detailsJSON(from payload: ItemPayload, existing: [String: OPVaultJSONValue]?) -> [String: OPVaultJSONValue] {
        var dict = existing ?? [:]

        // Only fields with no section origin go into the flat top-level array — section
        // fields are written back into their own original slot below instead, so editing
        // one never duplicates it into `fields` or otherwise disturbs the section. TOTP
        // fields never belong here even when new (no sectionSourceKey yet) — they always
        // live in `sections`, handled separately below.
        let flatFields = payload.fields.filter { $0.sectionSourceKey == nil && $0.type != .totp }
        let fieldsArray: [OPVaultJSONValue] = flatFields.map { field in
            let designation = field.type == .password ? "password" : (field.label.lowercased() == "username" ? "username" : "")
            return .object([
                "name": .string(field.label),
                "value": .string(field.value),
                "type": .string(field.type == .password ? "P" : "T"),
                "designation": .string(designation),
            ])
        }
        dict["fields"] = .array(fieldsArray)
        dict["notesPlain"] = .string(payload.notes ?? "")
        if dict["sections"] == nil { dict["sections"] = .array([]) }
        if dict["passwordHistory"] == nil { dict["passwordHistory"] = .array([]) }
        if let passwordField = flatFields.first(where: { $0.type == .password }) {
            dict["password"] = .string(passwordField.value)
        }

        let sectionFields = payload.fields.filter { $0.sectionSourceKey != nil }
        if !sectionFields.isEmpty, var sections = dict["sections"]?.arrayValue {
            for field in sectionFields {
                guard let key = field.sectionSourceKey else { continue }
                let parts = key.split(separator: ".", maxSplits: 1)
                guard parts.count == 2, let sectionIndex = Int(parts[0]), sectionIndex >= 0, sectionIndex < sections.count else { continue }
                let fieldN = String(parts[1])

                guard var sectionObj = sections[sectionIndex].objectValue,
                      var sectionFieldsArr = sectionObj["fields"]?.arrayValue,
                      let fieldIndex = sectionFieldsArr.firstIndex(where: { $0.objectValue?["n"]?.stringValue == fieldN }),
                      var fieldObj = sectionFieldsArr[fieldIndex].objectValue
                else { continue }

                fieldObj["v"] = .string(field.value)
                sectionFieldsArr[fieldIndex] = .object(fieldObj)
                sectionObj["fields"] = .array(sectionFieldsArr)
                sections[sectionIndex] = .object(sectionObj)
            }
            dict["sections"] = .array(sections)
        }

        // A `.totp` field with no `sectionSourceKey` was just added in this edit, not
        // loaded from an existing section — synthesize a new section-field entry for it
        // rather than dropping it. Real 1Password keeps one-time-password fields in the
        // item's default (first, often unnamed) section, so a fresh empty one is created
        // when none exists yet.
        let newTOTPFields = payload.fields.filter { $0.type == .totp && $0.sectionSourceKey == nil }
        if !newTOTPFields.isEmpty {
            var sections = dict["sections"]?.arrayValue ?? []
            if sections.isEmpty {
                sections = [.object(["name": .string(""), "title": .string(""), "fields": .array([])])]
            }
            var firstSection = sections[0].objectValue ?? ["name": .string(""), "title": .string(""), "fields": .array([])]
            var sectionFieldsArr = firstSection["fields"]?.arrayValue ?? []
            for field in newTOTPFields {
                let n = "TOTP_" + UUID().uuidString.replacingOccurrences(of: "-", with: "")
                sectionFieldsArr.append(.object([
                    "n": .string(n),
                    "t": .string("one-time password"),
                    "v": .string(field.value),
                    "k": .string("concealed"),
                ]))
            }
            firstSection["fields"] = .array(sectionFieldsArr)
            sections[0] = .object(firstSection)
            dict["sections"] = .array(sections)
        }

        return dict
    }

    private static func stringifiedFields(for item: OPVaultRawItem) -> [String: String] {
        var fields: [String: String] = [
            "category": item.category,
            "created": String(item.created),
            "updated": String(item.updated),
            "tx": String(item.tx),
            "fave": String(item.fave),
            "uuid": item.uuid,
            "k": item.k,
            "o": item.o,
            "d": item.d,
        ]
        if let trashed = item.trashed {
            fields["trashed"] = trashed ? "true" : "false"
        }
        return fields
    }

    private static func computeHMAC(for item: OPVaultRawItem, overviewMac: Data) -> Data {
        OPVaultCrypto.computeItemHMAC(sortedFieldsExcludingHMAC: stringifiedFields(for: item), overviewMac: overviewMac)
    }

    private static func randomBytes(_ count: Int) -> Data {
        var data = Data(count: count)
        _ = data.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, count, $0.baseAddress!) }
        return data
    }

    private static func overviewJSON(title: String, payload: ItemPayload) -> [String: OPVaultJSONValue] {
        var overview: [String: OPVaultJSONValue] = ["title": .string(title)]
        if let urlField = payload.fields.first(where: { $0.type == .url }), !urlField.value.isEmpty {
            overview["url"] = .string(urlField.value)
        }
        return overview
    }

    // MARK: - Create

    static func createItem(session: OPVaultSession, title: String, type: ItemType, payload: ItemPayload) throws -> OPVaultItemSummary {
        let uuid = UUID().uuidString.replacingOccurrences(of: "-", with: "")
        let now = Int(Date().timeIntervalSince1970)
        let category = OPVaultCategory.code(for: type)

        let itemEnc = randomBytes(32)
        let itemMac = randomBytes(32)

        let overview = overviewJSON(title: title, payload: payload)
        let overviewData = try JSONEncoder().encode(OPVaultJSONValue.object(overview))
        let oBlob = OPVaultCrypto.opdata01Encrypt(plaintext: overviewData, encKey: session.overviewEnc, macKey: session.overviewMac)

        let detailsDict = detailsJSON(from: payload, existing: nil)
        let detailsData = try JSONEncoder().encode(OPVaultJSONValue.object(detailsDict))
        let dBlob = OPVaultCrypto.opdata01Encrypt(plaintext: detailsData, encKey: itemEnc, macKey: itemMac)

        let kBlob = OPVaultCrypto.wrapItemKey(masterEnc: session.masterEnc, masterMac: session.masterMac, itemEnc: itemEnc, itemMac: itemMac)

        var item = OPVaultRawItem(
            category: category,
            created: now,
            updated: now,
            tx: now,
            fave: 0,
            trashed: nil,
            uuid: uuid,
            k: kBlob.base64EncodedString(),
            o: oBlob.base64EncodedString(),
            d: dBlob.base64EncodedString(),
            hmac: nil
        )
        item.hmac = computeHMAC(for: item, overviewMac: session.overviewMac).base64EncodedString()

        guard let letter = uuid.first else { throw OPVaultServiceError.itemNotFound }
        try OPVaultFileStore.mutateBand(profileDir: session.profileDir, letter: letter) { band in
            band[uuid] = item
        }

        return OPVaultItemSummary(
            uuid: uuid,
            category: category,
            title: title,
            url: overview["url"]?.stringValue,
            trashed: false,
            modifiedAt: Date(timeIntervalSince1970: TimeInterval(now))
        )
    }

    // MARK: - Update

    static func updateItem(session: OPVaultSession, uuid: String, title: String, payload: ItemPayload) throws {
        let upperUUID = uuid.uppercased()
        guard let letter = upperUUID.first,
              var item = OPVaultFileStore.loadBand(profileDir: session.profileDir, letter: letter)[upperUUID]
        else { throw OPVaultServiceError.itemNotFound }

        guard let kBlob = Data(base64Encoded: item.k) else { throw OPVaultServiceError.itemNotFound }
        let (itemEnc, itemMac) = try OPVaultCrypto.unwrapItemKey(masterEnc: session.masterEnc, masterMac: session.masterMac, blob: kBlob)

        var existingDetails: [String: OPVaultJSONValue] = [:]
        if let existingDBlob = Data(base64Encoded: item.d),
           let plain = try? OPVaultCrypto.opdata01Decrypt(existingDBlob, encKey: itemEnc, macKey: itemMac),
           let decoded = try? JSONDecoder().decode(OPVaultJSONValue.self, from: plain),
           let obj = decoded.objectValue {
            existingDetails = obj
        }

        let detailsDict = detailsJSON(from: payload, existing: existingDetails)
        let detailsData = try JSONEncoder().encode(OPVaultJSONValue.object(detailsDict))
        let dBlob = OPVaultCrypto.opdata01Encrypt(plaintext: detailsData, encKey: itemEnc, macKey: itemMac)

        let overview = overviewJSON(title: title, payload: payload)
        let overviewData = try JSONEncoder().encode(OPVaultJSONValue.object(overview))
        let oBlob = OPVaultCrypto.opdata01Encrypt(plaintext: overviewData, encKey: session.overviewEnc, macKey: session.overviewMac)

        item.o = oBlob.base64EncodedString()
        item.d = dBlob.base64EncodedString()
        item.updated = Int(Date().timeIntervalSince1970)
        item.tx = item.updated
        item.hmac = computeHMAC(for: item, overviewMac: session.overviewMac).base64EncodedString()

        try OPVaultFileStore.mutateBand(profileDir: session.profileDir, letter: letter) { band in
            band[upperUUID] = item
        }
    }

    // MARK: - Debug

    /// Pretty-printed JSON of the item exactly as stored on disk, for debugging: the raw
    /// band record (category/uuid/timestamps/trashed) plus its decrypted `details` blob
    /// verbatim — unlike `decryptPayload`, this skips the lossy mapping into `ItemPayload`
    /// so nothing (sections, passwordHistory, etc.) is dropped.
    static func debugJSON(session: OPVaultSession, uuid: String) throws -> String {
        guard let item = OPVaultFileStore.findItem(profileDir: session.profileDir, uuid: uuid) else {
            throw OPVaultServiceError.itemNotFound
        }
        guard let kBlob = Data(base64Encoded: item.k) else { throw OPVaultServiceError.itemNotFound }
        let (itemEnc, itemMac) = try OPVaultCrypto.unwrapItemKey(masterEnc: session.masterEnc, masterMac: session.masterMac, blob: kBlob)

        guard let dBlob = Data(base64Encoded: item.d) else { throw OPVaultServiceError.itemNotFound }
        let plain = try OPVaultCrypto.opdata01Decrypt(dBlob, encKey: itemEnc, macKey: itemMac)
        let details = try JSONDecoder().decode(OPVaultJSONValue.self, from: plain)

        let blob: [String: OPVaultJSONValue] = [
            "uuid": .string(item.uuid),
            "category": .string(item.category),
            "created": .number(Double(item.created)),
            "updated": .number(Double(item.updated)),
            "trashed": .bool(item.trashed ?? false),
            "details": details,
        ]

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(OPVaultJSONValue.object(blob))
        return String(data: data, encoding: .utf8) ?? "{}"
    }

    // MARK: - Soft delete

    /// Sets `trashed:true` and bumps `tx`/`updated`, matching real 1Password semantics.
    /// Deliberately does NOT recompute `hmac` — the confirmed hmac formula was only
    /// validated against non-trashed items; every real trashed item observed carries a
    /// stale hmac from whatever client trashed it, and native 1Password already
    /// tolerates that. See the plan's Safety semantics for the full reasoning.
    static func trashItem(session: OPVaultSession, uuid: String) throws {
        let upperUUID = uuid.uppercased()
        guard let letter = upperUUID.first else { throw OPVaultServiceError.itemNotFound }
        try OPVaultFileStore.mutateBand(profileDir: session.profileDir, letter: letter) { band in
            guard var item = band[upperUUID] else { return }
            item.trashed = true
            item.tx = Int(Date().timeIntervalSince1970)
            item.updated = item.tx
            band[upperUUID] = item
        }
    }
}
