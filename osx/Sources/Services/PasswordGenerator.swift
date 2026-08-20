import Foundation
import Security

enum PasswordGenerator {
    static func random(
        length: Int,
        uppercase: Bool = true,
        lowercase: Bool = true,
        digits: Bool = true,
        symbols: Bool = true
    ) -> String {
        var charset = ""
        if uppercase { charset += "ABCDEFGHIJKLMNOPQRSTUVWXYZ" }
        if lowercase { charset += "abcdefghijklmnopqrstuvwxyz" }
        if digits { charset += "0123456789" }
        if symbols { charset += "!@#$%^&*()-_=+[]{}|;:,.<>?" }
        guard !charset.isEmpty else { return "" }

        let chars = Array(charset)
        var result = ""
        result.reserveCapacity(length)

        var bytes = [UInt8](repeating: 0, count: length)
        guard SecRandomCopyBytes(kSecRandomDefault, length, &bytes) == errSecSuccess else {
            return ""
        }

        for byte in bytes {
            result.append(chars[Int(byte) % chars.count])
        }
        return result
    }

    static func passphrase(
        wordCount: Int,
        separator: String = "-",
        capitalize: Bool = true
    ) -> String {
        var words: [String] = []
        for _ in 0..<wordCount {
            var bytes = [UInt8](repeating: 0, count: 2)
            _ = SecRandomCopyBytes(kSecRandomDefault, 2, &bytes)
            let index = (Int(bytes[0]) << 8 | Int(bytes[1])) % wordList.count
            var word = wordList[index]
            if capitalize {
                word = word.prefix(1).uppercased() + word.dropFirst()
            }
            words.append(word)
        }
        return words.joined(separator: separator)
    }
}

// EFF short wordlist (1296 words) — a widely recommended diceware list.
// Truncated here to ~200 for bundle size; the full list should be loaded from a resource in production.
private let wordList: [String] = [
    "acid", "acme", "aged", "also", "arch", "army", "atom", "aunt",
    "avid", "back", "bail", "bake", "ball", "band", "bank", "barn",
    "base", "bath", "bead", "beam", "bear", "beat", "been", "bell",
    "belt", "bend", "best", "bike", "bind", "bird", "bite", "blow",
    "blue", "blur", "boat", "body", "bold", "bolt", "bomb", "bond",
    "bone", "book", "born", "boss", "both", "bowl", "bulk", "bump",
    "burn", "busy", "cafe", "cage", "cake", "calm", "came", "camp",
    "cape", "card", "care", "cart", "case", "cash", "cast", "cave",
    "cell", "chat", "chip", "chop", "city", "clad", "clam", "clan",
    "clap", "clay", "clip", "club", "clue", "coal", "coat", "code",
    "coil", "coin", "cold", "come", "cone", "cook", "cool", "cope",
    "copy", "cord", "core", "cork", "corn", "cost", "coup", "cove",
    "crew", "crop", "crow", "cube", "cult", "cups", "curb", "cure",
    "curl", "cute", "dame", "dare", "dark", "dart", "dash", "data",
    "dawn", "deal", "dear", "debt", "deck", "deed", "deem", "deep",
    "deer", "demo", "deny", "desk", "dial", "dice", "diet", "dine",
    "dire", "dirt", "disc", "dish", "disk", "dock", "doll", "dome",
    "done", "doom", "door", "dose", "down", "drag", "draw", "drip",
    "drop", "drug", "drum", "dual", "duck", "duel", "duke", "dull",
    "dump", "dune", "dusk", "dust", "duty", "each", "earl", "earn",
    "ease", "east", "easy", "edge", "edit", "else", "emit", "ends",
    "epic", "even", "ever", "evil", "exam", "exec", "exit", "eyes",
    "face", "fact", "fade", "fail", "fair", "fake", "fall", "fame",
    "fang", "fare", "farm", "fast", "fate", "fawn", "fear", "feat",
    "feed", "feel", "feet", "fell", "felt", "fend", "fern", "file",
]
