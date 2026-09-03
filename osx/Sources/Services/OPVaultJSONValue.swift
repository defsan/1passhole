import Foundation

/// A generic, order-preserving-enough JSON value used for OPVault item "details" blobs.
///
/// Real OPVault items (especially anything not created by 1Passhole itself) can carry
/// arbitrary schema — `sections`, `passwordHistory`, category-specific structures — that
/// 1Passhole doesn't render yet. Decoding details into this instead of a rigid struct lets
/// us update just the parts we understand (`fields`, `notesPlain`) while re-serializing
/// everything else completely untouched, so editing an item never silently drops data.
indirect enum OPVaultJSONValue: Codable, Equatable {
    case string(String)
    case number(Double)
    case bool(Bool)
    case object([String: OPVaultJSONValue])
    case array([OPVaultJSONValue])
    case null

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([String: OPVaultJSONValue].self) {
            self = .object(value)
        } else if let value = try? container.decode([OPVaultJSONValue].self) {
            self = .array(value)
        } else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unsupported JSON value")
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let value): try container.encode(value)
        case .number(let value): try container.encode(value)
        case .bool(let value): try container.encode(value)
        case .object(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .null: try container.encodeNil()
        }
    }

    var objectValue: [String: OPVaultJSONValue]? {
        if case .object(let value) = self { return value }
        return nil
    }

    var arrayValue: [OPVaultJSONValue]? {
        if case .array(let value) = self { return value }
        return nil
    }

    var stringValue: String? {
        if case .string(let value) = self { return value }
        return nil
    }

    /// Tolerant integer extraction: real-world OPVault items written by different clients
    /// over the years aren't perfectly consistent about numeric encoding, so this also
    /// accepts a numeric string rather than only a bare JSON number.
    var intValue: Int? {
        switch self {
        case .number(let value): Int(value)
        case .string(let value): Int(value)
        default: nil
        }
    }

    var boolValue: Bool? {
        switch self {
        case .bool(let value): value
        case .number(let value): value != 0
        default: nil
        }
    }
}
