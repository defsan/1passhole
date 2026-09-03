import Foundation

/// HTML-style nested form names as stored in OPVault (`user[email]`,
/// `data[pvpnetaccount][name]`). Parsing is display-only — the original string stays
/// on `ItemField.label` so an edit writes the same field name back.
struct FieldPath: Equatable {
    /// Prefix shown as a group header, e.g. `data[pvpnetaccount]` or `user`.
    var group: String
    /// Last segment shown as the field label, e.g. `name` or `email`.
    var leaf: String

    /// Parses a nested name. Returns nil for ordinary labels (`username`, `commit`)
    /// so those render ungrouped.
    static func parse(_ name: String) -> FieldPath? {
        guard let open = name.lastIndex(of: "["),
              name.hasSuffix("]"),
              open > name.startIndex
        else { return nil }
        let group = String(name[..<open])
        let leafStart = name.index(after: open)
        let leafEnd = name.index(before: name.endIndex)
        guard leafStart < leafEnd else { return nil }
        let leaf = String(name[leafStart..<leafEnd])
        guard !group.isEmpty, !leaf.contains("[") && !leaf.contains("]") else { return nil }
        return FieldPath(group: group, leaf: leaf)
    }

    /// Group title to show above `fields[index]`, if that field starts a new nested group.
    static func groupHeader(at index: Int, in fields: [ItemField]) -> String? {
        guard fields.indices.contains(index) else { return nil }
        guard let group = parse(fields[index].label)?.group else { return nil }
        if index > 0, parse(fields[index - 1].label)?.group == group {
            return nil
        }
        return group
    }

    /// Consecutive runs of fields that share a nested prefix, plus runs of ungrouped fields.
    static func groups(from fields: [ItemField]) -> [FieldGroup] {
        var grouped: [(title: String?, fields: [ItemField])] = []
        for field in fields {
            let title = parse(field.label)?.group
            if let last = grouped.last, last.title == title {
                grouped[grouped.count - 1].fields.append(field)
            } else {
                grouped.append((title, [field]))
            }
        }
        return grouped.map { FieldGroup(title: $0.title, fields: $0.fields) }
    }
}

struct FieldGroup: Identifiable {
    let title: String?
    let fields: [ItemField]

    var id: String {
        let titlePart = title ?? "_"
        let fieldPart = fields.map(\.id.uuidString).joined(separator: ",")
        return "\(titlePart)-\(fieldPart)"
    }
}

extension ItemField {
    /// Last path segment for UI (`user[email]` → `email`, `date_of_birth_month` →
    /// `date of birth month`). The stored `label` is never changed.
    var displayLabel: String {
        guard let leaf = FieldPath.parse(label)?.leaf else { return label }
        return leaf.replacingOccurrences(of: "_", with: " ")
    }
}
