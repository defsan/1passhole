import SwiftUI

enum SettingsTab: String, CaseIterable, Identifiable {
    case general
    case vault
    case appearance

    var id: String { rawValue }

    var title: String {
        switch self {
        case .general: "General"
        case .vault: "Vault"
        case .appearance: "Appearance"
        }
    }

    var icon: String {
        switch self {
        case .general: "gearshape.fill"
        case .vault: "lock.shield.fill"
        case .appearance: "paintbrush.fill"
        }
    }

    var color: Color {
        switch self {
        case .general: .gray
        case .vault: .blue
        case .appearance: .purple
        }
    }
}

struct SettingsView: View {
    @State private var selectedTab: SettingsTab = .general

    var body: some View {
        HStack(spacing: 0) {
            sidebar
            Divider()
            content
        }
        .frame(width: 620, height: 450)
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(SettingsTab.allCases) { tab in
                Button {
                    selectedTab = tab
                } label: {
                    HStack(spacing: 10) {
                        RoundedRectangle(cornerRadius: 6)
                            .fill(tab.color.gradient)
                            .frame(width: 26, height: 26)
                            .overlay {
                                Image(systemName: tab.icon)
                                    .font(.system(size: 13, weight: .semibold))
                                    .foregroundStyle(.white)
                            }

                        Text(tab.title)
                            .font(.body)
                            .foregroundStyle(selectedTab == tab ? .white : .primary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 6)
                    .padding(.horizontal, 8)
                    .background {
                        if selectedTab == tab {
                            RoundedRectangle(cornerRadius: 6)
                                .fill(.selection)
                        }
                    }
                }
                .buttonStyle(.plain)
            }
            Spacer()
        }
        .padding(12)
        .frame(width: 180)
    }

    @ViewBuilder
    private var content: some View {
        ScrollView {
            switch selectedTab {
            case .general:
                GeneralSettingsTab()
            case .vault:
                VaultSettingsTab()
            case .appearance:
                AppearanceSettingsTab()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
