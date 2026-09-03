import SwiftUI

enum OPVaultItemEditMode: Equatable {
    case create
    case edit(OPVaultItemSummary)
}

/// Live equivalent of `ItemEditView` for an OPVault connection. "Delete" here is a soft
/// delete (sets `trashed:true`) rather than removing the item outright — see
/// `OPVaultService.trashItem` for why.
struct OPVaultItemEditView: View {
    let session: OPVaultSession
    let mode: OPVaultItemEditMode
    var onDone: (OPVaultItemSummary?) -> Void

    @State private var title = ""
    @State private var selectedType: ItemType = .login
    @State private var fields: [ItemField] = []
    @State private var notes = ""
    @State private var errorMessage: String?
    @State private var showingGenerator = false

    private var isEditing: Bool {
        if case .edit = mode { return true }
        return false
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 14) {
                Image(systemName: isEditing ? "pencil.circle.fill" : "plus.circle.fill")
                    .font(.largeTitle)
                    .foregroundStyle(.tint)

                Text(isEditing ? "Edit Item" : "New Item")
                    .font(.title2.weight(.semibold))

                Spacer()

                Button("Cancel") { onDone(nil) }
                    .keyboardShortcut(.cancelAction)
            }
            .padding(24)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    TextField("Title", text: $title)
                        .textFieldStyle(.roundedBorder)
                        .font(.title3)

                    if !isEditing {
                        Picker("Type", selection: $selectedType) {
                            ForEach([ItemType.login, .creditCard, .identity, .secureNote], id: \.self) { type in
                                Label(type.displayName, systemImage: type.iconName)
                                    .tag(type)
                            }
                        }
                        .pickerStyle(.segmented)
                    }

                    Divider()

                    ForEach($fields) { $field in
                        HStack(spacing: 8) {
                            VStack(alignment: .leading, spacing: 4) {
                                if field.label.isEmpty {
                                    TextField("Field name", text: $field.label)
                                        .font(.caption.weight(.medium))
                                        .foregroundStyle(.secondary)
                                        .textCase(.uppercase)
                                } else {
                                    Text(field.label)
                                        .font(.caption.weight(.medium))
                                        .foregroundStyle(.secondary)
                                        .textCase(.uppercase)
                                }

                                if field.type == .password {
                                    HStack(spacing: 4) {
                                        SecureField("Value", text: $field.value)
                                            .textFieldStyle(.roundedBorder)
                                        Button {
                                            showingGenerator = true
                                        } label: {
                                            Image(systemName: "wand.and.stars")
                                        }
                                        .buttonStyle(.bordered)
                                    }
                                } else {
                                    TextField(field.label.isEmpty ? "Value" : field.label, text: $field.value)
                                        .textFieldStyle(.roundedBorder)
                                }
                            }

                            Button(role: .destructive) {
                                fields.removeAll { $0.id == field.id }
                            } label: {
                                Image(systemName: "minus.circle")
                            }
                            .buttonStyle(.borderless)
                        }
                    }

                    Button {
                        fields.append(ItemField(label: "", value: ""))
                    } label: {
                        Label("Add Field", systemImage: "plus.circle")
                    }
                    .buttonStyle(.borderless)

                    Divider()

                    Text("Notes")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)
                    TextEditor(text: $notes)
                        .frame(minHeight: 80)
                        .font(.body)
                        .scrollContentBackground(.hidden)
                        .padding(4)
                        .background(.background.secondary)
                        .clipShape(RoundedRectangle(cornerRadius: 6))

                    if let errorMessage {
                        Label(errorMessage, systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.red)
                    }
                }
                .padding(24)
            }

            Divider()

            HStack {
                if case .edit(let item) = mode {
                    Button("Delete", role: .destructive) {
                        trashItem(item)
                    }
                }
                Spacer()
                Button("Save") { save() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(title.isEmpty)
            }
            .padding(24)
        }
        .onAppear { loadExisting() }
        .onChange(of: selectedType) { applyTemplate() }
        .sheet(isPresented: $showingGenerator) {
            PasswordGeneratorView { generated in
                if let idx = fields.firstIndex(where: { $0.type == .password }) {
                    fields[idx].value = generated
                }
            }
        }
    }

    private func loadExisting() {
        if case .edit(let item) = mode {
            title = item.title
            selectedType = item.itemType
            if let payload = try? OPVaultService.decryptPayload(session: session, uuid: item.uuid) {
                fields = payload.fields
                notes = payload.notes ?? ""
            }
        } else {
            applyTemplate()
        }
    }

    private func applyTemplate() {
        guard !isEditing else { return }
        let template: ItemPayload
        switch selectedType {
        case .login: template = ItemTemplates.login()
        case .creditCard: template = ItemTemplates.creditCard()
        case .identity: template = ItemTemplates.identity()
        case .secureNote: template = ItemTemplates.secureNote()
        }
        fields = template.fields
        notes = template.notes ?? ""
    }

    private func save() {
        let payload = ItemPayload(fields: fields, notes: notes.isEmpty ? nil : notes)

        do {
            switch mode {
            case .create:
                let summary = try OPVaultService.createItem(session: session, title: title, type: selectedType, payload: payload)
                onDone(summary)
            case .edit(let item):
                try OPVaultService.updateItem(session: session, uuid: item.uuid, title: title, payload: payload)
                let updated = OPVaultItemSummary(
                    uuid: item.uuid,
                    category: item.category,
                    title: title,
                    url: payload.fields.first(where: { $0.type == .url })?.value,
                    trashed: item.trashed,
                    modifiedAt: .now
                )
                onDone(updated)
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func trashItem(_ item: OPVaultItemSummary) {
        try? OPVaultService.trashItem(session: session, uuid: item.uuid)
        onDone(nil)
    }
}
