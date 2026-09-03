import Foundation

/// Raw, still-encrypted item envelope, one per entry in a `band_<hex>.js` file.
/// Field names match the OPVault wire format exactly.
struct OPVaultRawItem: Codable, Equatable {
    var category: String
    var created: Int
    var updated: Int
    var tx: Int
    var fave: Int
    var trashed: Bool?
    var uuid: String
    var k: String
    var o: String
    var d: String
    var hmac: String?
}

extension OPVaultRawItem {
    /// Lenient, per-item construction from a generic JSON value. Real band files
    /// accumulated by different 1Password clients over many years aren't perfectly
    /// consistent — some very old items are missing `tx`, or encode a numeric field as a
    /// string. Decoding the *whole* band file as `[String: OPVaultRawItem]` in one shot
    /// (plain `Codable`) fails all-or-nothing: a single item like that would silently
    /// drop every other item in the same band. This instead only requires the fields
    /// actually needed to identify and decrypt an item, defaulting the rest.
    /// Kept in an extension (rather than the main struct body) so the compiler still
    /// synthesizes the ordinary memberwise initializer used everywhere else.
    init?(json: OPVaultJSONValue) {
        guard let obj = json.objectValue,
              let category = obj["category"]?.stringValue,
              let uuid = obj["uuid"]?.stringValue,
              let k = obj["k"]?.stringValue,
              let o = obj["o"]?.stringValue,
              let d = obj["d"]?.stringValue
        else { return nil }

        self.category = category
        self.uuid = uuid
        self.k = k
        self.o = o
        self.d = d
        self.created = obj["created"]?.intValue ?? 0
        self.updated = obj["updated"]?.intValue ?? 0
        self.tx = obj["tx"]?.intValue ?? obj["updated"]?.intValue ?? 0
        self.fave = obj["fave"]?.intValue ?? 0
        self.trashed = obj["trashed"]?.boolValue
        self.hmac = obj["hmac"]?.stringValue
    }
}

struct OPVaultProfile: Codable {
    var uuid: String
    var updatedAt: Int
    var createdAt: Int
    var iterations: Int
    var lastUpdatedBy: String?
    var profileName: String
    var salt: String
    var passwordHint: String?
    var masterKey: String
    var overviewKey: String
}

enum OPVaultFileStoreError: LocalizedError {
    case unwrapFailed(String)
    case profileNotFound

    var errorDescription: String? {
        switch self {
        case .unwrapFailed(let detail): "Could not parse OPVault file: \(detail)"
        case .profileNotFound: "No profile.js found at that location"
        }
    }
}

/// Reads and writes the on-disk OPVault bundle: `profile.js`, `band_<hex>.js` (0-9, A-F).
/// Every read re-parses the file from disk (Dropbox or another OPVault client may have
/// changed it since our last read); every write is atomic (temp file + rename) so a
/// crash or a sync mid-write can't corrupt the bundle.
enum OPVaultFileStore {
    static let bandLetters: [Character] = Array("0123456789ABCDEF")

    // MARK: - JS wrapper (de)serialization

    /// Strips `var profile=...;` / `ld(...);` wrappers and decodes the inner JSON.
    private static func decodeWrapped<T: Decodable>(
        _ text: String,
        prefixes: [(prefix: String, suffix: String)],
        as type: T.Type
    ) throws -> T {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        for (prefix, suffix) in prefixes {
            guard trimmed.hasPrefix(prefix) else { continue }
            var inner = trimmed
            inner.removeFirst(prefix.count)
            if inner.hasSuffix(suffix) {
                inner.removeLast(suffix.count)
            }
            let data = Data(inner.utf8)
            return try JSONDecoder().decode(T.self, from: data)
        }
        throw OPVaultFileStoreError.unwrapFailed("no matching wrapper for expected prefixes \(prefixes.map(\.prefix))")
    }

    // MARK: - profile.js

    static func loadProfile(profileDir: URL) throws -> OPVaultProfile {
        let url = profileDir.appendingPathComponent("profile.js")
        guard let text = try? String(contentsOf: url, encoding: .utf8) else {
            throw OPVaultFileStoreError.profileNotFound
        }
        return try decodeWrapped(text, prefixes: [("var profile=", ";")], as: OPVaultProfile.self)
    }

    // MARK: - band_<hex>.js

    private static func bandURL(profileDir: URL, letter: Character) -> URL {
        profileDir.appendingPathComponent("band_\(letter).js")
    }

    static func loadBand(profileDir: URL, letter: Character) -> [String: OPVaultRawItem] {
        let url = bandURL(profileDir: profileDir, letter: letter)
        guard let text = try? String(contentsOf: url, encoding: .utf8),
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            return [:]
        }
        // Decoded generically first, then constructed item-by-item (see
        // `OPVaultRawItem.init?(json:)`) rather than as one `[String: OPVaultRawItem]`
        // Codable dictionary — a single malformed/older item would otherwise fail that
        // whole decode and silently drop every other item sharing its band file.
        guard let raw = try? decodeWrapped(text, prefixes: [("ld(", ");")], as: [String: OPVaultJSONValue].self) else {
            return [:]
        }
        var result: [String: OPVaultRawItem] = [:]
        result.reserveCapacity(raw.count)
        for (uuid, value) in raw {
            guard let item = OPVaultRawItem(json: value) else { continue }
            result[uuid] = item
        }
        return result
    }

    /// Write-to-temp-then-rename: never truncates the live file in place.
    static func saveBand(profileDir: URL, letter: Character, items: [String: OPVaultRawItem]) throws {
        let payload = try JSONEncoder().encode(items)
        let json = String(data: payload, encoding: .utf8) ?? "{}"
        let wrapped = "ld(\(json));"

        let destination = bandURL(profileDir: profileDir, letter: letter)
        let tempURL = profileDir.appendingPathComponent(".band_\(letter)_\(UUID().uuidString).tmp")
        try wrapped.write(to: tempURL, atomically: true, encoding: .utf8)
        _ = try FileManager.default.replaceItemAt(destination, withItemAt: tempURL)
    }

    /// All items across every band file, re-read fresh from disk each call.
    static func iterItems(profileDir: URL) -> [(letter: Character, item: OPVaultRawItem)] {
        var result: [(Character, OPVaultRawItem)] = []
        for letter in bandLetters {
            for (_, item) in loadBand(profileDir: profileDir, letter: letter) {
                result.append((letter, item))
            }
        }
        return result
    }

    static func findItem(profileDir: URL, uuid: String) -> OPVaultRawItem? {
        guard let letter = uuid.uppercased().first else { return nil }
        return loadBand(profileDir: profileDir, letter: letter)[uuid.uppercased()]
    }

    /// Re-reads the specific band fresh, applies `mutate`, and writes it back atomically —
    /// the "always re-read before write" safety rule, kept in one place.
    static func mutateBand(
        profileDir: URL,
        letter: Character,
        mutate: (inout [String: OPVaultRawItem]) -> Void
    ) throws {
        var band = loadBand(profileDir: profileDir, letter: letter)
        mutate(&band)
        try saveBand(profileDir: profileDir, letter: letter, items: band)
    }
}
