import Foundation
import SwiftData

@Model
final class Vault {
    var id: UUID
    var name: String
    var iconName: String
    var createdAt: Date
    var modifiedAt: Date

    /// Vault symmetric key, encrypted with the master key (ciphertext + nonce + tag).
    var encryptedKey: Data

    @Relationship(deleteRule: .cascade, inverse: \Item.vault)
    var items: [Item] = []

    init(
        name: String,
        iconName: String = "lock.shield",
        encryptedKey: Data
    ) {
        self.id = UUID()
        self.name = name
        self.iconName = iconName
        self.createdAt = .now
        self.modifiedAt = .now
        self.encryptedKey = encryptedKey
    }
}
