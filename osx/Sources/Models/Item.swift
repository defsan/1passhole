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
}

struct ItemField: Codable, Identifiable {
    var id: UUID
    var label: String
    var value: String
    var type: FieldType
    var isConcealed: Bool

    init(label: String, value: String, type: FieldType = .text, isConcealed: Bool = false) {
        self.id = UUID()
        self.label = label
        self.value = value
        self.type = type
        self.isConcealed = isConcealed
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
