import SwiftUI

struct ItemDetailView: View {
    let item: Item
    var onEdit: () -> Void

    @Environment(AppState.self) private var appState
    @State private var payload: ItemPayload?
    @State private var revealedFields: Set<UUID> = []
    @State private var errorMessage: String?
    @State private var showMetadata = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                // Header
                HStack(spacing: 14) {
                    Image(systemName: item.type.iconName)
                        .font(.largeTitle)
                        .foregroundStyle(.tint)

                    VStack(alignment: .leading, spacing: 2) {
                        Text(item.title)
                            .font(.title2.weight(.semibold))
                        Text(item.type.displayName)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }

                    Spacer()

                    Button {
                        onEdit()
                    } label: {
                        Label("Edit", systemImage: "pencil")
                    }
                    .buttonStyle(.bordered)
                }

                if let errorMessage {
                    Label(errorMessage, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.red)
                }

                if let payload {
                    // Primary fields card (concealed + text fields)
                    let primaryFields = payload.fields.filter { $0.type != .url }
                    if !primaryFields.isEmpty {
                        GroupBox {
                            VStack(spacing: 0) {
                                ForEach(Array(primaryFields.enumerated()), id: \.element.id) { index, field in
                                    if index > 0 {
                                        Divider()
                                    }
                                    if field.type == .totp {
                                        TOTPFieldRow(field: field, onCopy: { code in
                                            ClipboardService.copy(code)
                                        })
                                    } else {
                                        DetailFieldRow(
                                            field: field,
                                            isRevealed: revealedFields.contains(field.id),
                                            onToggleReveal: {
                                                if revealedFields.contains(field.id) {
                                                    revealedFields.remove(field.id)
                                                } else {
                                                    revealedFields.insert(field.id)
                                                }
                                            },
                                            onCopy: {
                                                ClipboardService.copy(field.value)
                                            }
                                        )
                                    }
                                }
                            }
                        }
                        .groupBoxStyle(CardGroupBoxStyle())
                    }

                    // URL fields (outside card)
                    let urlFields = payload.fields.filter { $0.type == .url }
                    ForEach(urlFields) { field in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(field.label.lowercased())
                                .font(.subheadline)
                                .foregroundStyle(.tint)

                            if let url = URL(string: field.value), !field.value.isEmpty {
                                Link(destination: url) {
                                    Text(field.value)
                                        .font(.body)
                                }
                            } else {
                                Text(field.value)
                                    .font(.body)
                                    .textSelection(.enabled)
                            }
                        }
                        .padding(.horizontal, 4)
                    }

                    // Notes
                    if let notes = payload.notes, !notes.isEmpty {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("notes")
                                .font(.subheadline)
                                .foregroundStyle(.tint)
                            Text(notes)
                                .font(.body)
                                .textSelection(.enabled)
                        }
                        .padding(.horizontal, 4)
                    }
                }

                Spacer()

                // Collapsible metadata
                DisclosureGroup(isExpanded: $showMetadata) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Created \(item.createdAt.formatted(date: .complete, time: .shortened))")
                        Text("Modified \(item.modifiedAt.formatted(date: .complete, time: .shortened))")
                    }
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .padding(.top, 4)
                } label: {
                    Text("Last edited \(item.modifiedAt.formatted(date: .complete, time: .standard))")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(24)
        }
        .onAppear { decrypt() }
        .onChange(of: item) { decrypt() }
    }

    private func decrypt() {
        revealedFields = []
        let service = VaultService(
            modelContext: appState.modelContainer.mainContext,
            crypto: appState.cryptoEngine
        )
        do {
            payload = try service.decryptItem(item)
            errorMessage = nil
        } catch {
            payload = nil
            errorMessage = error.localizedDescription
        }
    }
}

// MARK: - Field row styled like 1Password

struct DetailFieldRow: View {
    let field: ItemField
    let isRevealed: Bool
    let onToggleReveal: () -> Void
    let onCopy: () -> Void

    @State private var isHovering = false

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            VStack(alignment: .leading, spacing: 3) {
                Text(field.label.lowercased())
                    .font(.subheadline)
                    .foregroundStyle(.tint)

                if field.isConcealed && !isRevealed {
                    Text(String(repeating: "●", count: 10))
                        .font(.body)
                        .foregroundStyle(.primary)
                } else {
                    Text(field.value)
                        .font(.body)
                        .textSelection(.enabled)
                }
            }

            Spacer()

            if isHovering {
                HStack(spacing: 8) {
                    if field.isConcealed {
                        Button {
                            onToggleReveal()
                        } label: {
                            Image(systemName: isRevealed ? "eye.slash" : "eye")
                                .font(.system(size: 24))
                        }
                        .buttonStyle(.borderless)
                    }

                    Button {
                        onCopy()
                    } label: {
                        Image(systemName: "doc.on.doc")
                            .font(.system(size: 24))
                    }
                    .buttonStyle(.borderless)
                }
            }
        }
        .padding(.vertical, 10)
        .padding(.horizontal, 4)
        .contentShape(Rectangle())
        .onHover { hovering in
            isHovering = hovering
        }
        .onTapGesture {
            onCopy()
        }
    }
}

// MARK: - Card style GroupBox

struct CardGroupBoxStyle: GroupBoxStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.content
            .padding(.horizontal, 12)
            .background {
                RoundedRectangle(cornerRadius: 8)
                    .fill(.background)
                    .stroke(.separator, lineWidth: 1)
            }
    }
}
