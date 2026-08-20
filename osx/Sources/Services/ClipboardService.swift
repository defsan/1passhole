import AppKit
import Foundation

@MainActor
enum ClipboardService {
    private static var clearTask: Task<Void, Never>?

    /// Default auto-clear timeout in seconds (5 minutes).
    static var clearTimeout: TimeInterval = 300

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
            try? await Task.sleep(for: .seconds(clearTimeout))
            guard !Task.isCancelled else { return }
            NSPasteboard.general.clearContents()
        }
    }
}
