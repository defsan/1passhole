import Foundation
import AppKit

/// Helps the user locate an existing 1Password `.opvault` bundle and turns the pick into
/// a security-scoped bookmark the sandboxed app can re-access across launches.
///
/// This deliberately does NOT add a `temporary-exception` entitlement to silently scan
/// the disk for Dropbox — for a password manager, keeping the sandbox as tight as
/// possible is worth more than a slightly smarter first-run guess. The only smartness
/// here is: (1) defaulting the picker's starting folder to the most likely location,
/// and (2) a best-effort, failure-tolerant read of `~/.dropbox/info.json` in case the
/// sandbox happens to allow it — never required.
enum OPVaultLocator {
    /// Presents an NSOpenPanel for the user to choose their `.opvault` bundle.
    /// Returns the chosen URL (with an active security scope) or nil if cancelled.
    @MainActor
    static func pickVaultFolder() -> URL? {
        let panel = NSOpenPanel()
        panel.title = "Connect 1Password Vault"
        panel.message = "Select your 1Password.opvault folder (usually inside a Dropbox folder)."
        panel.prompt = "Connect"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = guessStartingDirectory()

        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        return url
    }

    /// Best-effort guess at where to start browsing. Never required to succeed — if the
    /// sandbox blocks these existence checks, `FileManager` just returns false and we
    /// fall back to the home directory, which NSOpenPanel can always browse from
    /// (the panel runs with the user's own privileges, independent of our sandbox).
    private static func guessStartingDirectory() -> URL {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let fm = FileManager.default

        if let realDropboxPath = readRealDropboxPath() {
            let candidate = URL(fileURLWithPath: realDropboxPath).appendingPathComponent("1Password")
            if fm.fileExists(atPath: candidate.path) { return candidate }
        }

        let candidates = [
            home.appendingPathComponent("Dropbox/1Password"),
            home.appendingPathComponent("Library/CloudStorage/Dropbox/1Password"),
            home.appendingPathComponent("Dropbox"),
        ]
        for candidate in candidates where fm.fileExists(atPath: candidate.path) {
            return candidate
        }
        return home
    }

    /// Dropbox writes its real, per-install sync path(s) to `~/.dropbox/info.json`.
    /// Reading it is a nice-to-have, not a requirement — if the sandbox denies it,
    /// this silently returns nil and callers fall back to static guesses.
    private static func readRealDropboxPath() -> String? {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let infoURL = home.appendingPathComponent(".dropbox/info.json")
        guard let data = try? Data(contentsOf: infoURL) else { return nil }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        // Typical shape: {"personal": {"path": "..."}, "business": {"path": "..."}}
        for key in ["personal", "business"] {
            if let entry = json[key] as? [String: Any], let path = entry["path"] as? String {
                return path
            }
        }
        return nil
    }

    // MARK: - Security-scoped bookmarks

    static func makeBookmark(for url: URL) throws -> Data {
        try url.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil)
    }

    /// Resolves a stored bookmark back to a URL. The caller is responsible for calling
    /// `startAccessingSecurityScopedResource()`/`stopAccessingSecurityScopedResource()`
    /// around actual file access (see `OPVaultService`).
    static func resolveBookmark(_ data: Data) throws -> (url: URL, isStale: Bool) {
        var isStale = false
        let url = try URL(
            resolvingBookmarkData: data,
            options: .withSecurityScope,
            relativeTo: nil,
            bookmarkDataIsStale: &isStale
        )
        return (url, isStale)
    }

    /// Lists the profile subdirectories (each containing its own `profile.js`) inside a
    /// chosen `.opvault` bundle. Real-world bundles almost always have exactly one,
    /// named "default".
    static func profileNames(in vaultFolder: URL) -> [String] {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(at: vaultFolder, includingPropertiesForKeys: [.isDirectoryKey]) else {
            return []
        }
        return entries
            .filter { fm.fileExists(atPath: $0.appendingPathComponent("profile.js").path) }
            .map(\.lastPathComponent)
            .sorted()
    }

    /// The user is asked to pick the `.opvault` bundle itself, but it's an easy mistake to
    /// instead pick its *parent* folder (e.g. `~/Dropbox/1Password/`, one level up from
    /// `1Password.opvault/`) — `profile.js` would then be two levels down, not one, and
    /// `profileNames(in:)` would find nothing. If the picked folder has no profiles of its
    /// own but contains exactly one `*.opvault` bundle, descend into that automatically.
    /// The returned URL is always still within the sandbox scope the user granted, since
    /// NSOpenPanel access covers the whole subtree of whatever folder was picked.
    static func resolveVaultBundle(from folder: URL) -> URL {
        if !profileNames(in: folder).isEmpty {
            return folder
        }

        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.isDirectoryKey]) else {
            return folder
        }
        let opvaultBundles = entries.filter { $0.pathExtension.lowercased() == "opvault" }
        if opvaultBundles.count == 1, let bundle = opvaultBundles.first, !profileNames(in: bundle).isEmpty {
            return bundle
        }
        return folder
    }
}
