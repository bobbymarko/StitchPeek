import AppKit
import SwiftUI

@main
struct StitchPeekApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @Environment(\.openWindow) private var openWindow
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        // One window per batch of designs, identified by its collection. A window with no
        // collection is the empty state, and adopts the next batch that arrives.
        WindowGroup(id: "collection", for: UUID.self) { $collectionID in
            CollectionWindow(collectionID: $collectionID)
        }
        // Opt the scene out of URL handling entirely. Left at its default, WindowGroup
        // treats every opened file as an external event and spawns a window per URL —
        // on top of the delegate receiving the same files. Three files became five windows.
        .handlesExternalEvents(matching: [])
        .defaultSize(width: 1100, height: 720)
        // When the app is launched *to open files*, SwiftUI makes no window at all — the
        // delegate receives the batch and nothing would ever show it. `openWindow` is only
        // handed out through the environment, so capture it here, at the first scene-phase
        // change, and let the library flush whatever arrived before then.
        .onChange(of: scenePhase, initial: true) { _, _ in
            Library.shared.openWindow = { openWindow(id: "collection", value: $0) }
            Library.shared.flushPending()
        }
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Open…") { Library.shared.presentOpenPanel() }
                    .keyboardShortcut("o", modifiers: .command)
                RecentDocumentsMenu()
            }
        }
    }
}

/// `DocumentGroup` used to provide this for free; without it the list has to be read from
/// `NSDocumentController`, which still records what we open and keeps the sandbox access.
private struct RecentDocumentsMenu: View {
    var body: some View {
        let recent = NSDocumentController.shared.recentDocumentURLs
        Menu("Open Recent") {
            ForEach(recent, id: \.self) { url in
                Button(url.lastPathComponent) { Library.shared.open([url]) }
            }
            if !recent.isEmpty { Divider() }
            Button("Clear Menu") { NSDocumentController.shared.clearRecentDocuments(nil) }
                .disabled(recent.isEmpty)
        }
    }
}
