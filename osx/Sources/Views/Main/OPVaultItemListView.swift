import SwiftUI

/// One item plus its pre-decrypted searchable text (title + non-secret fields + notes),
/// built once per refresh rather than per keystroke — a real vault here can hold 1000+
/// items, so re-decrypting all of them on every keystroke would be wasteful.
private struct SearchableEntry {
    let summary: OPVaultItemSummary
    let searchableText: String
    let usernamePreview: String?
}

/// Live equivalent of `ItemListView` for an unlocked OPVault connection: lists items by
/// decrypting every overview blob fresh from disk. `refreshToken` lets the caller force
/// a reload after a create/edit/delete (there's no `@Query`-style live observation for
/// data that lives in plain files on disk).
struct OPVaultItemListView: View {
    let session: OPVaultSession
    @Binding var selectedItem: SelectedItem?
    var refreshToken: Int = 0
    var searchFocusTrigger: Int = 0

    @State private var entries: [SearchableEntry] = []
    @State private var searchQuery = ""
    @FocusState private var searchFocused: Bool

    /// Multiple space-separated words are OR'd (an item needs only one to appear at all),
    /// but ranked by how many of the words it matched — an item matching every word
    /// floats to the top, ahead of ones matching only some.
    private var filteredEntries: [SearchableEntry] {
        let words = SearchRanking.words(in: searchQuery)
        guard !words.isEmpty else { return entries }

        let scored: [(entry: SearchableEntry, score: Int)] = entries.compactMap { entry in
            let score = SearchRanking.score(words: words, in: entry.searchableText)
            return score > 0 ? (entry, score) : nil
        }
        return scored.sorted { $0.score > $1.score }.map(\.entry)
    }

    var body: some View {
        VStack(spacing: 0) {
            InlineSearchField(query: $searchQuery, isFocused: $searchFocused)

            List(selection: $selectedItem) {
                ForEach(filteredEntries, id: \.summary.id) { entry in
                    OPVaultItemRow(item: entry.summary, usernamePreview: entry.usernamePreview)
                        .tag(SelectedItem.opvault(entry.summary))
                }
            }
            .listStyle(.inset)
            .overlay {
                if filteredEntries.isEmpty {
                    if searchQuery.isEmpty {
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
            ItemCountStatusBar(count: filteredEntries.count)
        }
        .task(id: refreshToken) {
            entries = OPVaultService.listItems(session: session).map { summary in
                let payload = try? OPVaultService.decryptPayload(session: session, uuid: summary.uuid)
                let text = payload.map { Self.searchableText(title: summary.title, payload: $0) } ?? summary.title
                return SearchableEntry(summary: summary, searchableText: text, usernamePreview: payload?.usernamePreview)
            }
        }
        .onChange(of: searchFocusTrigger) {
            searchFocused = true
        }
    }

    private static func searchableText(title: String, payload: ItemPayload) -> String {
        title + " " + payload.nonSecretSearchableText
    }
}

struct OPVaultItemRow: View {
    let item: OPVaultItemSummary
    var usernamePreview: String?

    @AppStorage(SettingsKey.compactMode) private var compactMode: Bool = false

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: item.itemType.iconName)
                .font(.title3)
                .foregroundStyle(.secondary)
                .frame(width: 24)

            VStack(alignment: .leading, spacing: compactMode ? 1 : 2) {
                Text(item.title)
                    .font(.body.weight(.medium))
                    .lineLimit(1)

                if !compactMode {
                    Text(usernamePreview ?? item.itemType.displayName)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
        }
        .padding(.vertical, compactMode ? 0 : 2)
    }
}
