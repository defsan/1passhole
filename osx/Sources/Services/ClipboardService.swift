import AppKit
import Foundation

@MainActor
enum ClipboardService {
    private static var clearTask: Task<Void, Never>?

    private static var effectiveTimeout: TimeInterval {
        let stored = UserDefaults.standard.double(forKey: SettingsKey.clipboardTimeout)
        return stored > 0 ? stored : 300
    }

    /// Copy a string to the pasteboard, scheduling auto-clear.
    static func copy(_ string: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(string, forType: .string)
        scheduleClear()
    }

    /// Cancel any pending clear and schedule a new one.
    private static func scheduleClear() {
        clearTask?.cancel()
        clearTask = Task {
            try? await Task.sleep(for: .seconds(effectiveTimeout))
            guard !Task.isCancelled else { return }
            NSPasteboard.general.clearContents()
        }
    }
}
