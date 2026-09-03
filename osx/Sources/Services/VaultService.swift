import Foundation
import SwiftData
import CryptoKit

/// CRUD operations for vaults and items, always working with encrypted data.
@Observable
final class VaultService {
    private let modelContext: ModelContext
    private let crypto: CryptoEngine

    init(modelContext: ModelContext, crypto: CryptoEngine) {
        self.modelContext = modelContext
        self.crypto = crypto
    }

    // MARK: - Vault operations

    func createVault(name: String) throws -> Vault {
        let encryptedKey = try crypto.generateEncryptedVaultKey()
        let vault = Vault(name: name, encryptedKey: encryptedKey)
        modelContext.insert(vault)
        try modelContext.save()
        return vault
    }

    func deleteVault(_ vault: Vault) throws {
        modelContext.delete(vault)
        try modelContext.save()
    }

    func renameVault(_ vault: Vault, to name: String) throws {
        vault.name = name
        vault.modifiedAt = .now
        try modelContext.save()
    }

    func fetchVaults() throws -> [Vault] {
        let descriptor = FetchDescriptor<Vault>(sortBy: [SortDescriptor(\.name)])
        return try modelContext.fetch(descriptor)
    }

    // MARK: - Item operations

    func createItem(
        title: String,
        type: ItemType,
        payload: ItemPayload,
        in vault: Vault
    ) throws -> Item {
        let vaultKey = try crypto.decryptVaultKey(from: vault.encryptedKey)
        let encryptedPayload = try crypto.encryptPayload(payload, using: vaultKey)
        let item = Item(title: title, type: type, vault: vault, encryptedPayload: encryptedPayload)
        modelContext.insert(item)
        try modelContext.save()
        return item
    }

    func updateItem(_ item: Item, title: String, payload: ItemPayload) throws {
        guard let vault = item.vault else { return }
        let vaultKey = try crypto.decryptVaultKey(from: vault.encryptedKey)
        item.title = title
        item.encryptedPayload = try crypto.encryptPayload(payload, using: vaultKey)
        item.modifiedAt = .now
        try modelContext.save()
    }

    func deleteItem(_ item: Item) throws {
        modelContext.delete(item)
        try modelContext.save()
    }

    func decryptItem(_ item: Item) throws -> ItemPayload {
        guard let vault = item.vault else { throw CryptoError.decryptionFailed }
        let vaultKey = try crypto.decryptVaultKey(from: vault.encryptedKey)
        return try crypto.decryptPayload(from: item.encryptedPayload, using: vaultKey)
    }

    /// Pretty-printed JSON of the decrypted item, verbatim, for debugging — the exact
    /// plaintext structure that gets encrypted into `encryptedPayload`, plus the
    /// unencrypted metadata columns alongside it.
    func debugJSON(for item: Item) throws -> String {
        let payload = try decryptItem(item)
        let blob = ItemDebugBlob(
            id: item.id,
            title: item.title,
            type: item.type,
            createdAt: item.createdAt,
            modifiedAt: item.modifiedAt,
            vaultID: item.vault?.id,
            payload: payload
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(blob)
        return String(data: data, encoding: .utf8) ?? "{}"
    }

    func fetchItems(in vault: Vault? = nil, matching search: String = "") throws -> [Item] {
        var predicate: Predicate<Item>?
        if let vault {
            let vaultId = vault.id
            if search.isEmpty {
                predicate = #Predicate { $0.vault?.id == vaultId }
            } else {
                predicate = #Predicate {
                    $0.vault?.id == vaultId && $0.title.localizedStandardContains(search)
                }
            }
        } else if !search.isEmpty {
            predicate = #Predicate { $0.title.localizedStandardContains(search) }
        }

        var descriptor = FetchDescriptor<Item>(
            predicate: predicate,
            sortBy: [SortDescriptor(\.modifiedAt, order: .reverse)]
        )
        descriptor.fetchLimit = 500
        return try modelContext.fetch(descriptor)
    }
}

private struct ItemDebugBlob: Encodable {
    let id: UUID
    let title: String
    let type: ItemType
    let createdAt: Date
    let modifiedAt: Date
    let vaultID: UUID?
    let payload: ItemPayload
}
