import Foundation

/// Maps between OPVault's category codes and 1Passhole's own `ItemType`.
/// Only Login/Credit Card/Secure Note/Identity have a clean equivalent; every other
/// OPVault category (Bank Account, Membership, Software License, ...) displays as a
/// Secure Note for now — all of its actual field data is still preserved, only the
/// icon/type badge is approximate. `code(for:)` is only used when 1Passhole itself
/// creates a brand-new item, so it only needs to cover the four real cases.
enum OPVaultCategory {
    static func itemType(for code: String) -> ItemType {
        switch code {
        case "001": .login
        case "002": .creditCard
        case "003": .secureNote
        case "004": .identity
        default: .secureNote
        }
    }

    static func code(for type: ItemType) -> String {
        switch type {
        case .login: "001"
        case .creditCard: "002"
        case .secureNote: "003"
        case .identity: "004"
        }
    }

    static let displayNames: [String: String] = [
        "001": "Login",
        "002": "Credit Card",
        "003": "Secure Note",
        "004": "Identity",
        "005": "Password",
        "006": "Tombstone",
        "100": "Software License",
        "101": "Bank Account",
        "102": "Database",
        "103": "Driver License",
        "104": "Outdoor License",
        "105": "Membership",
        "106": "Passport",
        "107": "Rewards Program",
        "108": "Social Security Number",
        "109": "Router",
        "110": "Server",
        "111": "Email Account",
    ]
}
