import SwiftUI
import SwiftData

enum DetailMode: Equatable {
    case viewing
    case editing(Item)
    case creating
}

struct MainView: View {
    @Environment(AppState.self) private var appState
    @State private var searchText = ""
    @State private var detailMode: DetailMode = .viewing
    var body: some View {
        @Bindable var state = appState

        NavigationSplitView {
            SidebarView(selectedVault: $state.selectedVault)
                .navigationSplitViewColumnWidth(min: 180, ideal: 220, max: 280)
        } content: {
            ItemListView(
                vault: appState.selectedVault,
                searchText: searchText,
                selectedItem: $state.selectedItem
            )
            .navigationSplitViewColumnWidth(min: 220, ideal: 280, max: 360)
        } detail: {
            detailPanel
        }
        .searchable(text: $searchText, prompt: "Search items")
        .toolbar {
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

    @ViewBuilder
    private var detailPanel: some View {
        switch detailMode {
        case .viewing:
            if let item = appState.selectedItem {
                ItemDetailView(item: item) {
                    detailMode = .editing(item)
                }
            } else {
                ContentUnavailableView(
                    "No Item Selected",
                    systemImage: "key",
                    description: Text("Select an item from the list to view its details.")
                )
            }

        case .editing(let item):
            if let vault = item.vault {
                ItemEditView(vault: vault, mode: .edit(item)) {
                    detailMode = .viewing
                }
            }

        case .creating:
            if let vault = appState.selectedVault {
                ItemEditView(vault: vault, mode: .create) {
                    detailMode = .viewing
                }
            }
        }
    }
}
