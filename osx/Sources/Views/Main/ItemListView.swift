import SwiftUI
import SwiftData

struct ItemListView: View {
    let vault: Vault?
    let searchText: String
    @Binding var selectedItem: Item?

    @Environment(AppState.self) private var appState
    @Query(sort: \Item.modifiedAt, order: .reverse) private var allItems: [Item]

    private var filteredItems: [Item] {
        var items = allItems
        if let vault {
            items = items.filter { $0.vault?.id == vault.id }
        }
        if !searchText.isEmpty {
            items = items.filter {
                $0.title.localizedCaseInsensitiveContains(searchText)
            }
        }
        return items
    }

    var body: some View {
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
                        "Select a Vault",
                        systemImage: "sidebar.left",
                        description: Text("Choose a vault from the sidebar.")
                    )
                } else if searchText.isEmpty {
                    ContentUnavailableView(
                        "No Items",
                        systemImage: "plus.circle",
                        description: Text("Click + to add your first item.")
                    )
                } else {
                    ContentUnavailableView.search(text: searchText)
                }
            }
        }
    }
}

struct ItemRow: View {
    let item: Item

    @AppStorage(SettingsKey.compactMode) private var compactMode: Bool = false

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
                    Text(item.type.displayName)
                        .font(.caption)
                        .foregroundStyle(.secondary)
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
