import SwiftUI

/// Detail-panel rendering of fields, splitting nested names like `user[email]` into
/// a group titled `user` whose rows only show the last segment. Ungrouped fields
/// (ordinary `username` / `commit`) stay in their own card. Stored labels are untouched.
struct GroupedDetailFields: View {
    let fields: [ItemField]
    @Binding var revealedFields: Set<UUID>

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            ForEach(FieldPath.groups(from: fields)) { group in
                VStack(alignment: .leading, spacing: 6) {
                    if let title = group.title {
                        NestedFieldGroupHeader(title: title)
                    }
                    GroupBox {
                        VStack(spacing: 0) {
                            ForEach(Array(group.fields.enumerated()), id: \.element.id) { index, field in
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
            }
        }
    }
}

struct NestedFieldGroupHeader: View {
    let title: String
    var isFirst: Bool = false

    var body: some View {
        Text(title)
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
            .textSelection(.enabled)
            .padding(.top, isFirst ? 0 : 4)
            .padding(.horizontal, 4)
    }
}
