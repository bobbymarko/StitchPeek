import AppKit

/// Receives files from Finder. With no `DocumentGroup` in the app, this is how a
/// double-click (or a multi-file selection opened together) reaches us: one call, all URLs.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    func application(_ application: NSApplication, open urls: [URL]) {
        Library.shared.open(urls)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }
}

