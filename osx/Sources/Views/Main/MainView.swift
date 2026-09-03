import SwiftUI
import SwiftData

enum DetailMode: Equatable {
    case viewing
    case editing(SelectedItem)
    case creating
}

struct MainView: View {
    @Environment(AppState.self) private var appState
    @State private var detailMode: DetailMode = .viewing
    @State private var opvaultRefreshToken = 0
    @State private var searchFocusTrigger = 0

    var body: some View {
        NavigationSplitView {
            contentColumn
                .navigationSplitViewColumnWidth(min: 240, ideal: 300, max: 400)
        } detail: {
            detailPanel
        }
        .toolbar {
            ToolbarItem(placement: .automatic) {
                Button {
                    searchFocusTrigger += 1
                } label: {
                    Label("Search", systemImage: "magnifyingglass")
                }
                .keyboardShortcut("k", modifiers: .command)
            }

            ToolbarItem(placement: .primaryAction) {
                Button {
                    createNewItem()
                } label: {
                    Label("New Item", systemImage: "plus")
                }
                .keyboardShortcut("n")
                .disabled(appState.selectedVault == nil)
            }

            ToolbarItem(placement: .automatic) {
                Button {
                    appState.lock()
                } label: {
                    Label("Lock", systemImage: "lock")
                }
            }
        }
        .onChange(of: appState.selectedItem) {
            detailMode = .viewing
        }
    }

    private func createNewItem() {
        guard appState.selectedVault != nil else { return }
        detailMode = .creating
    }

    /// Adapts `AppState.selectedItem` (the `SelectedItem` enum) to the plain `Item?`
    /// binding the unmodified native `ItemListView` expects.
    private var nativeSelectedItemBinding: Binding<Item?> {
        Binding(
            get: {
                if case .native(let item)? = appState.selectedItem { return item }
                return nil
            },
            set: { newValue in
                appState.selectedItem = newValue.map { SelectedItem.native($0) }
            }
        )
    }

    @ViewBuilder
    private var contentColumn: some View {
        @Bindable var state = appState
        switch appState.selectedVault {
        case .native(let vault):
            ItemListView(vault: vault, selectedItem: nativeSelectedItemBinding, searchFocusTrigger: searchFocusTrigger)
        case .opvault(let connection):
            if let session = appState.opvaultSessions[connection.id] {
                OPVaultItemListView(
                    session: session,
                    selectedItem: $state.selectedItem,
                    refreshToken: opvaultRefreshToken,
                    searchFocusTrigger: searchFocusTrigger
                )
            } else {
                OPVaultUnlockView(connection: connection)
            }
        case nil:
            ItemListView(vault: nil, selectedItem: nativeSelectedItemBinding, searchFocusTrigger: searchFocusTrigger)
        }
    }

    @ViewBuilder
    private var detailPanel: some View {
        switch detailMode {
        case .viewing:
            switch appState.selectedItem {
            case .native(let item):
                ItemDetailView(item: item) {
                    detailMode = .editing(.native(item))
                }
            case .opvault(let summary):
                if case .opvault(let connection)? = appState.selectedVault,
                   let session = appState.opvaultSessions[connection.id] {
                    OPVaultItemDetailView(session: session, item: summary) {
                        detailMode = .editing(.opvault(summary))
                    }
                }
            case nil:
                ContentUnavailableView(
                    "No Item Selected",
                    systemImage: "key",
                    description: Text("Select an item from the list to view its details.")
                )
            }

        case .editing(let selected):
            switch selected {
            case .native(let item):
                if let vault = item.vault {
                    ItemEditView(vault: vault, mode: .edit(item)) {
                        detailMode = .viewing
                    }
                }
            case .opvault(let summary):
                if case .opvault(let connection)? = appState.selectedVault,
                   let session = appState.opvaultSessions[connection.id] {
                    OPVaultItemEditView(session: session, mode: .edit(summary)) { updated in
                        appState.selectedItem = updated.map { SelectedItem.opvault($0) }
                        opvaultRefreshToken += 1
                        detailMode = .viewing
                    }
                }
            }

        case .creating:
            switch appState.selectedVault {
            case .native(let vault):
                ItemEditView(vault: vault, mode: .create) {
                    detailMode = .viewing
                }
            case .opvault(let connection):
                if let session = appState.opvaultSessions[connection.id] {
                    OPVaultItemEditView(session: session, mode: .create) { created in
                        appState.selectedItem = created.map { SelectedItem.opvault($0) }
                        opvaultRefreshToken += 1
                        detailMode = .viewing
                    }
                }
            case nil:
                EmptyView()
            }
        }
    }
}
