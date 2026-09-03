import AppKit

/// 1passhole has a single main window and no document model, so closing it should quit
/// the app (like a typical utility app) rather than leaving a windowless app running.
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }
}
