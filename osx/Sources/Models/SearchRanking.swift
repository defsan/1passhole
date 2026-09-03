import Foundation

/// Shared multi-word search scoring used by both item list views. Space-separated words
/// are OR'd — an item needs only one to match at all — but results are ranked by how
/// many of the words matched, so an item matching every word floats above one matching
/// only some.
enum SearchRanking {
    static func words(in query: String) -> [String] {
        query.split(whereSeparator: \.isWhitespace).map(String.init)
    }

    /// Number of `words` that appear (case-insensitively) anywhere in `text`.
    static func score(words: [String], in text: String) -> Int {
        words.reduce(into: 0) { count, word in
            if text.localizedCaseInsensitiveContains(word) { count += 1 }
        }
    }
}
