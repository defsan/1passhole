import Foundation

/// Lightweight, non-persisted summary of one OPVault item — just enough to list/search
/// without decrypting full details. Built by decrypting every item's `o` (overview) blob.
struct OPVaultItemSummary: Identifiable, Hashable {
    let uuid: String
    var id: String { uuid }
    let category: String
    let title: String
    let url: String?
    let trashed: Bool
    let modifiedAt: Date

    var itemType: ItemType { OPVaultCategory.itemType(for: category) }
}

/// The currently selected vault, which may be a native SwiftData vault or a live
/// OPVault connection. Both `Vault` and `OPVaultConnection` are SwiftData `@Model`
/// classes and already conform to `Hashable`, so this enum's conformance is derived.
enum SelectedVault: Hashable {
    case native(Vault)
    case opvault(OPVaultConnection)

    var name: String {
        switch self {
        case .native(let vault): vault.name
        case .opvault(let connection): connection.name
        }
    }

    var iconName: String {
        switch self {
        case .native(let vault): vault.iconName
        case .opvault(let connection): connection.iconName
        }
    }
}

/// The currently selected item, which may be a native SwiftData item or a live
/// OPVault item summary.
enum SelectedItem: Hashable {
    case native(Item)
    case opvault(OPVaultItemSummary)
}
