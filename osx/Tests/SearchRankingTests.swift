import Testing
@testable import OnePasshole

struct SearchRankingTests {
    @Test func singleWordScoresOneWhenPresent() {
        let words = SearchRanking.words(in: "github")
        #expect(SearchRanking.score(words: words, in: "GitHub Login") == 1)
        #expect(SearchRanking.score(words: words, in: "Unrelated Item") == 0)
    }

    @Test func multiWordIsOrMatchNotAndMatch() {
        let words = SearchRanking.words(in: "github work")
        // Only one of the two words present — still counts as a match (OR), just scores lower.
        #expect(SearchRanking.score(words: words, in: "github personal account") == 1)
    }

    @Test func multiWordFullMatchScoresHigherThanPartialMatch() {
        let words = SearchRanking.words(in: "github work")
        let fullMatchScore = SearchRanking.score(words: words, in: "github work account")
        let partialMatchScore = SearchRanking.score(words: words, in: "github personal account")
        #expect(fullMatchScore > partialMatchScore)
        #expect(fullMatchScore == 2)
        #expect(partialMatchScore == 1)
    }

    @Test func sortingByScorePutsFullMatchesFirst() {
        struct Entry { let name: String; let text: String }
        let words = SearchRanking.words(in: "blue sky")
        let entries = [
            Entry(name: "onlyBlue", text: "blue ocean"),
            Entry(name: "both", text: "blue sky ranch"),
            Entry(name: "neither", text: "red car"),
            Entry(name: "onlySky", text: "night sky"),
        ]

        let ranked = entries
            .map { ($0, SearchRanking.score(words: words, in: $0.text)) }
            .filter { $0.1 > 0 }
            .sorted { $0.1 > $1.1 }
            .map(\.0.name)

        #expect(ranked.first == "both")
        #expect(ranked.count == 3) // "neither" excluded entirely
        #expect(!ranked.contains("neither"))
    }

    @Test func emptyQueryHasNoWords() {
        #expect(SearchRanking.words(in: "").isEmpty)
        #expect(SearchRanking.words(in: "   ").isEmpty)
    }
}
