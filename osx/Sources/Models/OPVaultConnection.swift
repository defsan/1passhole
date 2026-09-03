import Foundation
import SwiftData

/// Persisted *pointer* to a live 1Password OPVault bundle — never holds item data.
/// Items always live in, and are read fresh from, the actual `.opvault` folder on disk;
/// this model just remembers where that folder is (via a security-scoped bookmark) and
/// which named profile inside it to use.
@Model
final class OPVaultConnection {
    var id: UUID
    var name: String
    var iconName: String
    var bookmarkData: Data
    var profileName: String
    var createdAt: Date
    var modifiedAt: Date

    init(
        name: String,
        iconName: String = "person.badge.key.fill",
        bookmarkData: Data,
        profileName: String
    ) {
        self.id = UUID()
        self.name = name
        self.iconName = iconName
        self.bookmarkData = bookmarkData
        self.profileName = profileName
        self.createdAt = .now
        self.modifiedAt = .now
    }
}
