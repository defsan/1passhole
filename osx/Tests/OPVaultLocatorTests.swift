import Testing
import Foundation
@testable import OnePasshole

/// Covers the bug where picking the *parent* of a `.opvault` bundle (e.g.
/// `~/Dropbox/1Password/`, one level up from `1Password.opvault/`) found no profiles,
/// since `profile.js` is two levels down from the parent, not one.
struct OPVaultLocatorTests {
    private func makeVaultBundle(in parent: URL, name: String = "1Password.opvault", profile: String = "default") throws -> URL {
        let bundle = parent.appendingPathComponent(name)
        let profileDir = bundle.appendingPathComponent(profile)
        try FileManager.default.createDirectory(at: profileDir, withIntermediateDirectories: true)
        try Data("var profile={};".utf8).write(to: profileDir.appendingPathComponent("profile.js"))
        return bundle
    }

    @Test func resolvesWhenBundleItselfIsPicked() throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let bundle = try makeVaultBundle(in: tmp)
        let resolved = OPVaultLocator.resolveVaultBundle(from: bundle)

        #expect(resolved.resolvingSymlinksInPath().path == bundle.resolvingSymlinksInPath().path)
        #expect(OPVaultLocator.profileNames(in: resolved) == ["default"])
    }

    @Test func resolvesWhenParentFolderIsPickedInstead() throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        // Sibling files that a real Dropbox/1Password folder also contains, to make sure
        // they don't confuse the scan.
        try Data().write(to: tmp.appendingPathComponent("1Password.kdbx"))
        try Data().write(to: tmp.appendingPathComponent("export.csv"))

        let bundle = try makeVaultBundle(in: tmp)
        let resolved = OPVaultLocator.resolveVaultBundle(from: tmp)

        #expect(resolved.resolvingSymlinksInPath().path == bundle.resolvingSymlinksInPath().path)
        #expect(OPVaultLocator.profileNames(in: resolved) == ["default"])
    }

    @Test func leavesFolderUnchangedWhenNothingFound() throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let resolved = OPVaultLocator.resolveVaultBundle(from: tmp)

        #expect(resolved.resolvingSymlinksInPath().path == tmp.resolvingSymlinksInPath().path)
        #expect(OPVaultLocator.profileNames(in: resolved).isEmpty)
    }

    @Test func doesNotGuessWhenMultipleBundlesArePresent() throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        _ = try makeVaultBundle(in: tmp, name: "Work.opvault")
        _ = try makeVaultBundle(in: tmp, name: "Personal.opvault")

        let resolved = OPVaultLocator.resolveVaultBundle(from: tmp)

        // Ambiguous — leave it to the caller to report "no profile found" rather than
        // silently picking one of several vaults.
        #expect(resolved.resolvingSymlinksInPath().path == tmp.resolvingSymlinksInPath().path)
    }
}
