import SwiftUI
import SwiftData

struct SidebarView: View {
    @Binding var selectedVault: Vault?

    @Environment(AppState.self) private var appState
    @Query(sort: \Vault.name) private var vaults: [Vault]

    @AppStorage(SettingsKey.sidebarIconSize) private var sidebarIconSize: String = "medium"
    @AppStorage(SettingsKey.compactMode) private var compactMode: Bool = false

    @State private var showingNewVault = false
    @State private var newVaultName = ""

    private var iconFont: Font {
        switch sidebarIconSize {
        case "small": .body
        case "large": .title2
        default: .title3
        }
    }

    var body: some View {
        List(selection: $selectedVault) {
            Section("Vaults") {
                ForEach(vaults) { vault in
                    Label {
                        Text(vault.name)
                    } icon: {
                        Image(systemName: vault.iconName)
                            .font(iconFont)
                    }
                    .padding(.vertical, compactMode ? 0 : 2)
                    .tag(vault)
                        .contextMenu {
                            Button("Rename...") { renameVault(vault) }
                            Divider()
                            Button("Delete", role: .destructive) { deleteVault(vault) }
                        }
                }
            }
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .bottom) {
            Button {
                showingNewVault = true
            } label: {
                Label("New Vault", systemImage: "plus.circle")
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
            }
            .buttonStyle(.plain)
        }
        .alert("New Vault", isPresented: $showingNewVault) {
            TextField("Vault name", text: $newVaultName)
            Button("Create") { createVault() }
            Button("Cancel", role: .cancel) { newVaultName = "" }
        }
        .onAppear {
            if selectedVault == nil, let first = vaults.first {
                selectedVault = first
            }
        }
    }

    private func createVault() {
        guard !newVaultName.isEmpty else { return }
        let service = VaultService(
            modelContext: appState.modelContainer.mainContext,
            crypto: appState.cryptoEngine
        )
        _ = try? service.createVault(name: newVaultName)
        newVaultName = ""
    }

    private func deleteVault(_ vault: Vault) {
        let service = VaultService(
            modelContext: appState.modelContainer.mainContext,
            crypto: appState.cryptoEngine
        )
        if selectedVault == vault { selectedVault = nil }
        try? service.deleteVault(vault)
    }

    private func renameVault(_ vault: Vault) {
        // For v1, rename is handled inline. A full rename sheet can come later.
        newVaultName = vault.name
        showingNewVault = true
    }
}
