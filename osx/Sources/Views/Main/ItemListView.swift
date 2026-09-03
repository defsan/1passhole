import SwiftUI
import SwiftData

struct ItemListView: View {
    let vault: Vault?
    @Binding var selectedItem: Item?
    var searchFocusTrigger: Int = 0

    @Environment(AppState.self) private var appState
    @Query(sort: \Item.modifiedAt, order: .reverse) private var allItems: [Item]
    @State private var searchQuery = ""
    @FocusState private var searchFocused: Bool

    private var vaultItems: [Item] {
        guard let vault else { return allItems }
        return allItems.filter { $0.vault?.id == vault.id }
    }

    /// Matches title first (cheap), then decrypts to check non-secret fields/notes.
    /// Native vaults are small enough that decrypting per keystroke is imperceptible —
    /// no need for the cached-index approach `OPVaultItemListView` uses for 1000+ items.
    private var filteredItems: [Item] {
        guard !searchQuery.isEmpty else { return vaultItems }
        let crypto = appState.cryptoEngine
        return vaultItems.filter { item in
            if item.title.localizedCaseInsensitiveContains(searchQuery) { return true }
            guard let vault = item.vault,
                  let vaultKey = try? crypto.decryptVaultKey(from: vault.encryptedKey),
                  let payload = try? crypto.decryptPayload(from: item.encryptedPayload, using: vaultKey)
            else { return false }
            return payload.fields.contains { field in
                !field.isConcealed && field.type != .password &&
                    (field.label.localizedCaseInsensitiveContains(searchQuery) ||
                     field.value.localizedCaseInsensitiveContains(searchQuery))
            } || (payload.notes?.localizedCaseInsensitiveContains(searchQuery) ?? false)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            if vault != nil {
                InlineSearchField(query: $searchQuery, isFocused: $searchFocused)
            }

            List(selection: $selectedItem) {
                ForEach(filteredItems) { item in
                    ItemRow(item: item)
                        .tag(item)
                }
            }
            .listStyle(.inset)
            .overlay {
                if filteredItems.isEmpty {
                    if vault == nil {
                        ContentUnavailableView(
                            "No Vault Selected",
                            systemImage: "lock.shield",
                            description: Text("Open Settings (⌘,) to create or switch to a vault.")
                        )
                    } else if searchQuery.isEmpty {
                        ContentUnavailableView(
                            "No Items",
                            systemImage: "plus.circle",
                            description: Text("Click + to add your first item.")
                        )
                    } else {
                        ContentUnavailableView.search(text: searchQuery)
                    }
                }
            }
        }
        .safeAreaInset(edge: .bottom) {
            if vault != nil {
                ItemCountStatusBar(count: filteredItems.count)
            }
        }
        .onChange(of: searchFocusTrigger) {
            searchFocused = true
        }
    }
}

struct ItemRow: View {
    let item: Item

    @Environment(AppState.self) private var appState
    @AppStorage(SettingsKey.compactMode) private var compactMode: Bool = false

    /// Username if the item has one, else the item type — computed on demand rather than
    /// cached, which is fine at native-vault sizes (typically dozens to low hundreds).
    private var subtitle: String {
        guard let vault = item.vault,
              let vaultKey = try? appState.cryptoEngine.decryptVaultKey(from: vault.encryptedKey),
              let payload = try? appState.cryptoEngine.decryptPayload(from: item.encryptedPayload, using: vaultKey),
              let username = payload.usernamePreview
        else {
            return item.type.displayName
        }
        return username
    }

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: item.type.iconName)
                .font(.title3)
                .foregroundStyle(.secondary)
                .frame(width: 24)

            VStack(alignment: .leading, spacing: compactMode ? 1 : 2) {
                Text(item.title)
                    .font(.body.weight(.medium))
                    .lineLimit(1)

                if !compactMode {
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
        }
        .padding(.vertical, compactMode ? 0 : 2)
    }
}

extension ItemType {
    var iconName: String {
        switch self {
        case .login: "person.circle"
        case .creditCard: "creditcard"
        case .identity: "person.text.rectangle"
        case .secureNote: "note.text"
        }
    }

    var displayName: String {
        switch self {
        case .login: "Login"
        case .creditCard: "Credit Card"
        case .identity: "Identity"
        case .secureNote: "Secure Note"
        }
    }
}
