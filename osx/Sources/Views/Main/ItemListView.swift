import SwiftUI
import SwiftData

struct ItemListView: View {
    let vault: Vault?
    @Binding var selectedItem: Item?
    var searchFocusTrigger: Int = 0
    var onEdit: (Item) -> Void = { _ in }
    var onDelete: (Item) -> Void = { _ in }

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
    ///
    /// Multiple space-separated words are OR'd (an item needs only one to appear at
    /// all), but ranked by how many of the words it matched — an item matching every
    /// word floats to the top, ahead of ones matching only some.
    private var filteredItems: [Item] {
        let words = SearchRanking.words(in: searchQuery)
        guard !words.isEmpty else { return vaultItems }

        let crypto = appState.cryptoEngine
        let scored: [(item: Item, score: Int)] = vaultItems.compactMap { item in
            var text = item.title
            if let vault = item.vault,
               let vaultKey = try? crypto.decryptVaultKey(from: vault.encryptedKey),
               let payload = try? crypto.decryptPayload(from: item.encryptedPayload, using: vaultKey) {
                text += " " + payload.nonSecretSearchableText
            }
            let score = SearchRanking.score(words: words, in: text)
            return score > 0 ? (item, score) : nil
        }
        return scored.sorted { $0.score > $1.score }.map(\.item)
    }

    var body: some View {
        VStack(spacing: 0) {
            if vault != nil {
                InlineSearchField(query: $searchQuery, isFocused: $searchFocused)
            }

            List(selection: $selectedItem) {
                ForEach(filteredItems) { item in
                    ItemRow(item: item, onEdit: onEdit, onDelete: onDelete)
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
    var onEdit: (Item) -> Void = { _ in }
    var onDelete: (Item) -> Void = { _ in }

    @Environment(AppState.self) private var appState
    @AppStorage(SettingsKey.compactMode) private var compactMode: Bool = false
    @State private var showDeleteConfirm = false

    private var vaultService: VaultService {
        VaultService(modelContext: appState.modelContainer.mainContext, crypto: appState.cryptoEngine)
    }

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
        .contextMenu {
            Button {
                onEdit(item)
            } label: {
                Label("Edit", systemImage: "pencil")
            }

            Button {
                copyPassword()
            } label: {
                Label("Copy Password", systemImage: "key")
            }

            Button {
                copyBlob()
            } label: {
                Label("Copy Blob", systemImage: "curlybraces")
            }

            Divider()

            Button(role: .destructive) {
                showDeleteConfirm = true
            } label: {
                Label("Delete", systemImage: "trash")
            }
        }
        .confirmationDialog(
            "Delete “\(item.title)”?",
            isPresented: $showDeleteConfirm,
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) {
                onDelete(item)
            }
        }
    }

    private func copyPassword() {
        guard let payload = try? vaultService.decryptItem(item),
              let password = payload.fields.first(where: { $0.type == .password })
        else { return }
        ClipboardService.copy(password.value)
    }

    private func copyBlob() {
        guard let json = try? vaultService.debugJSON(for: item) else { return }
        ClipboardService.copy(json)
    }
}

extension ItemType {
    var iconName: String {
        switch self {
        case .login: "person.circle"
        case .creditCard: "creditcard"
        case .identity: "person.text.rectangle"
        case .secureNote: "note.text"
        case .password: "key"
        }
    }

    var displayName: String {
        switch self {
        case .login: "Login"
        case .creditCard: "Credit Card"
        case .identity: "Identity"
        case .secureNote: "Secure Note"
        case .password: "Password"
        }
    }
}
