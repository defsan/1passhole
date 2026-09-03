import Foundation
import SwiftData

enum ItemType: String, Codable, CaseIterable {
    case login
    case creditCard
    case identity
    case secureNote
}

@Model
final class Item {
    var id: UUID
    var vault: Vault?

    /// Unencrypted metadata for search/display without decryption.
    var title: String
    var type: ItemType
    var createdAt: Date
    var modifiedAt: Date

    /// The full item payload, encrypted with the vault key.
    /// Contains a JSON-encoded `ItemPayload` as ciphertext + nonce + tag.
    var encryptedPayload: Data

    init(
        title: String,
        type: ItemType,
        vault: Vault,
        encryptedPayload: Data
    ) {
        self.id = UUID()
        self.title = title
        self.type = type
        self.vault = vault
        self.createdAt = .now
        self.modifiedAt = .now
        self.encryptedPayload = encryptedPayload
    }
}

// MARK: - Decrypted payload types (never persisted directly)

struct ItemPayload: Codable {
    var fields: [ItemField]
    var notes: String?

    /// First field that looks like a username, for list-row previews. Never a
    /// concealed/password field.
    var usernamePreview: String? {
        fields.first {
            !$0.isConcealed && $0.type != .password &&
                ($0.label.localizedCaseInsensitiveCompare("username") == .orderedSame || $0.type == .email)
        }.map(\.value).flatMap { $0.isEmpty ? nil : $0 }
    }

    /// Every non-secret field's label/value plus notes, joined for search matching.
    /// Never includes concealed/password fields. Title isn't included here since callers
    /// already have that separately.
    var nonSecretSearchableText: String {
        var parts: [String] = []
        for field in fields where !field.isConcealed && field.type != .password {
            parts.append(field.label)
            parts.append(field.value)
        }
        if let notes {
            parts.append(notes)
        }
        return parts.joined(separator: " ")
    }
}

struct ItemField: Codable, Identifiable {
    var id: UUID
    var label: String
    var value: String
    var type: FieldType
    var isConcealed: Bool

    /// Where this field actually lives in an OPVault item's `details` JSON, when it came
    /// from a nested `sections` entry rather than the flat top-level `fields` array — e.g.
    /// `"3.user[login]"` (section index 3, original field id `user[login]`). `nil` for
    /// every native field and every flat OPVault field. Preserved through edits so a
    /// value change writes back into that exact original slot instead of being flattened
    /// into the top-level array, which would duplicate/misplace it and break the
    /// section's structure for other 1Password clients.
    var sectionSourceKey: String?

    init(label: String, value: String, type: FieldType = .text, isConcealed: Bool = false, sectionSourceKey: String? = nil) {
        self.id = UUID()
        self.label = label
        self.value = value
        self.type = type
        self.isConcealed = isConcealed
        self.sectionSourceKey = sectionSourceKey
    }
}

enum FieldType: String, Codable {
    case text
    case password
    case url
    case email
    case totp
    case phone
    case date
    case monthYear
    case creditCardNumber
}
