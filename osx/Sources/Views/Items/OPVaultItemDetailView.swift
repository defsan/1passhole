import SwiftUI

/// Live equivalent of `ItemDetailView` for an OPVault item — same card-based layout,
/// reusing `DetailFieldRow`/`CardGroupBoxStyle` from ItemDetailView.swift, just sourced
/// from `OPVaultService` instead of `VaultService`.
struct OPVaultItemDetailView: View {
    let session: OPVaultSession
    let item: OPVaultItemSummary
    var onEdit: () -> Void

    @State private var payload: ItemPayload?
    @State private var revealedFields: Set<UUID> = []
    @State private var errorMessage: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                HStack(spacing: 14) {
                    Image(systemName: item.itemType.iconName)
                        .font(.largeTitle)
                        .foregroundStyle(.tint)

                    VStack(alignment: .leading, spacing: 2) {
                        Text(item.title)
                            .font(.title2.weight(.semibold))
                        Text(item.itemType.displayName)
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
                    let primaryFields = payload.fields.filter { $0.type != .url }
                    if !primaryFields.isEmpty {
                        GroupBox {
                            VStack(spacing: 0) {
                                ForEach(Array(primaryFields.enumerated()), id: \.element.id) { index, field in
                                    if index > 0 {
                                        Divider()
                                    }
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
                        .groupBoxStyle(CardGroupBoxStyle())
                    }

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

                Text("Last edited \(item.modifiedAt.formatted(date: .complete, time: .standard))")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .padding(24)
        }
        .onAppear { decrypt() }
        .onChange(of: item) { decrypt() }
    }

    private func decrypt() {
        revealedFields = []
        do {
            payload = try OPVaultService.decryptPayload(session: session, uuid: item.uuid)
            errorMessage = nil
        } catch {
            payload = nil
            errorMessage = error.localizedDescription
        }
    }
}
