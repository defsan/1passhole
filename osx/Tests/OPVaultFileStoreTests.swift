import Testing
import Foundation
@testable import OnePasshole

/// Covers a real bug: real OPVault band files accumulated by different 1Password clients
/// over many years aren't perfectly consistent (some very old items omit `tx` entirely,
/// or encode a number as a string). Decoding a whole band file as one
/// `[String: OPVaultRawItem]` `Codable` dictionary fails all-or-nothing, so a single item
/// like that silently dropped *every* item sharing its band file — in practice this
/// showed up as a vault with 1000+ real items listing only ~56 (one lucky band's worth).
struct OPVaultFileStoreTests {
    private func writeBand(_ json: String, letter: Character, in profileDir: URL) throws {
        try "ld(\(json));".write(to: profileDir.appendingPathComponent("band_\(letter).js"), atomically: true, encoding: .utf8)
    }

    @Test func malformedItemDoesNotDropTheRestOfTheBand() throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        // A normal, fully-formed item; an old item missing `tx` entirely; and one where
        // `fave` is encoded as a string instead of a number — all real-world shapes.
        let json = """
        {
          "0AAAAAAAAAAA4A4AAAAAAAAAAAAA": {"category":"001","created":1,"updated":1,"tx":1,"fave":0,"uuid":"0AAAAAAAAAAA4A4AAAAAAAAAAAAA","k":"k1","o":"o1","d":"d1"},
          "0BBBBBBBBBBB4B4BBBBBBBBBBBBB": {"category":"001","created":1,"updated":1,"fave":0,"uuid":"0BBBBBBBBBBB4B4BBBBBBBBBBBBB","k":"k2","o":"o2","d":"d2"},
          "0CCCCCCCCCCC4C4CCCCCCCCCCCCC": {"category":"003","created":1,"updated":1,"tx":1,"fave":"0","uuid":"0CCCCCCCCCCC4C4CCCCCCCCCCCCC","k":"k3","o":"o3","d":"d3"}
        }
        """
        try writeBand(json, letter: "0", in: tmp)

        let band = OPVaultFileStore.loadBand(profileDir: tmp, letter: "0")

        #expect(band.count == 3)
        #expect(band["0AAAAAAAAAAA4A4AAAAAAAAAAAAA"] != nil)
        #expect(band["0BBBBBBBBBBB4B4BBBBBBBBBBBBB"]?.tx == 1) // defaulted from `updated`
        #expect(band["0CCCCCCCCCCC4C4CCCCCCCCCCCCC"]?.fave == 0) // tolerantly parsed from "0"
    }

    @Test func itemsMissingCoreFieldsAreSkippedNotFatal() throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        // Second item has no "d" (details blob) at all — genuinely unusable, should be
        // skipped, but must not take the first (valid) item down with it.
        let json = """
        {
          "0AAAAAAAAAAA4A4AAAAAAAAAAAAA": {"category":"001","created":1,"updated":1,"tx":1,"fave":0,"uuid":"0AAAAAAAAAAA4A4AAAAAAAAAAAAA","k":"k1","o":"o1","d":"d1"},
          "0BBBBBBBBBBB4B4BBBBBBBBBBBBB": {"category":"001","created":1,"updated":1,"tx":1,"fave":0,"uuid":"0BBBBBBBBBBB4B4BBBBBBBBBBBBB","k":"k2","o":"o2"}
        }
        """
        try writeBand(json, letter: "0", in: tmp)

        let band = OPVaultFileStore.loadBand(profileDir: tmp, letter: "0")

        #expect(band.count == 1)
        #expect(band["0AAAAAAAAAAA4A4AAAAAAAAAAAAA"] != nil)
        #expect(band["0BBBBBBBBBBB4B4BBBBBBBBBBBBB"] == nil)
    }
}
