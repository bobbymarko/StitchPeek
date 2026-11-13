import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Reaches the hosting NSWindow for what SwiftUI on macOS 14 has no API for:
///
/// - switching off state restoration — collections are not persisted, so a window restored
///   from a previous launch would only ever point at nothing (`restorationBehavior` arrived
///   in macOS 15);
/// - closing the window deterministically. `dismissWindow()` proved unreliable for windows
///   that are still being created at launch, and a spurious window that survives is exactly
///   the bug this exists to prevent;
/// - opening as a tab of the front window rather than as a window of its own.
struct WindowConfigurator: NSViewRepresentable {
    var closes: Bool

    func makeNSView(context: Context) -> WindowHookView {
        let view = WindowHookView()
        view.closes = closes
        return view
    }

    func updateNSView(_ view: WindowHookView, context: Context) {
        view.closes = closes
        view.applyIfReady()
    }
}

/// Configures its window the moment it is attached — before the window is first shown, so
/// a new tab joins its group instead of flashing up as a window first.
final class WindowHookView: NSView {
    var closes = false
    private var tabbed = false

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        applyIfReady()
    }

    func applyIfReady() {
        guard let window else { return }
        window.isRestorable = false
        if closes {
            DispatchQueue.main.async { window.close() }
            return
        }
        guard !tabbed else { return }
        tabbed = true
        WindowTabbing.adopt(window)
    }
}

/// Every StitchPeek window shares one tabbing identifier and prefers tabs, and a new one
/// joins the front window's tab group. Native window tabs rather than a home-made tab
/// strip: the tab shortcuts, Merge All Windows, dragging a tab out into its own window and
/// Move Tab to New Window all come with them.
@MainActor
enum WindowTabbing {
    static let identifier = "com.bobbymarko.stitchpeek.collection"

    static func adopt(_ window: NSWindow) {
        window.tabbingIdentifier = identifier
        window.tabbingMode = .preferred

        let others = NSApp.orderedWindows.filter {
            $0 !== window && $0.tabbingIdentifier == identifier && $0.isVisible && !$0.isMiniaturized
        }
        // The window you're looking at, else the frontmost one of ours.
        let host = NSApp.mainWindow.flatMap { main in others.contains(main) ? main : nil } ?? others.first
        guard let host, window.tabbedWindows?.contains(host) != true else { return }
        host.addTabbedWindow(window, ordered: .above)
        window.makeKeyAndOrderFront(nil)
    }
}

/// The root of every window. Shows the collection it was opened for, or the empty state
/// while it waits to be handed one.
struct CollectionWindow: View {
    @Binding var collectionID: UUID?
    @Environment(\.openWindow) private var openWindow
    @State private var token = UUID()
    @State private var closeRequested = false
    @State private var feedbackDraft: FeedbackDraft?

    private var library: Library { Library.shared }

    private var currentCollection: DesignCollection? {
        collectionID.flatMap { library.collection($0) }
    }

    var body: some View {
        Group {
            if let collectionID, let collection = library.collection(collectionID) {
                CollectionView(collection: collection)
                    .onDisappear { library.forget(collectionID) }
            } else {
                EmptyStateView(onFeedback: beginFeedback)
            }
        }
        // Fill the window before pinning the banner to the top. WindowGroup centres a root
        // view that is shorter than the window, and the empty state is only as tall as its
        // contents — so without this the banner floated a third of the way down.
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .safeAreaInset(edge: .top, spacing: 0) { UpdateBanner() }
        .sheet(item: $feedbackDraft) { FeedbackSheet(draft: $0) }
        .focusedSceneValue(\.feedbackAction, FeedbackAction(perform: beginFeedback))
        .focusedSceneValue(\.activeCollection, currentCollection)
        .onAppear {
            library.openWindow = { openWindow(id: "collection", value: $0) }

            // Collections are not persisted, so a window macOS restores from a previous
            // launch points at nothing. Treat it as empty.
            if let collectionID, library.collection(collectionID) == nil {
                self.collectionID = nil
            }
            if let collectionID { library.windowDidAppear(for: collectionID) }

            if collectionID == nil {
                // A batch waiting from before this window existed always wins — this is the
                // window a Finder double-click lands in.
                if let waiting = library.takePending() {
                    collectionID = waiting.id
                    library.windowDidAppear(for: waiting.id)
                    return
                }
                // At launch, an empty window alongside a batch (or a second empty one) is noise:
                // SwiftUI's own launch window, or one macOS restored. After launch, an empty
                // window is one the person asked for — ⌘T or the tab bar's + — so it stays.
                if library.isLaunching && (library.hasEmptyWindow || library.hasOpenCollections) {
                    closeRequested = true
                    return
                }
                library.registerEmptyWindow(token: token, adopt: {
                    collectionID = $0.id
                    library.windowDidAppear(for: $0.id)
                }, replace: {
                    // An .emb opened as its own tab beside this one: close this empty one.
                    closeRequested = true
                })
            }
        }
        .background(WindowConfigurator(closes: closeRequested))
        .onChange(of: collectionID) { _, newValue in
            if newValue != nil { library.unregisterEmptyWindow(token: token) }
        }
        .onDisappear { library.unregisterEmptyWindow(token: token) }
    }

    /// Captures this window *before* the sheet covers it, then opens the sheet.
    private func beginFeedback() {
        guard feedbackDraft == nil else { return }
        feedbackDraft = FeedbackDraft(
            screenshot: FeedbackCapture.window(NSApp.keyWindow),
            context: FeedbackContext.current(collection: currentCollection)
        )
    }
}

private struct EmptyStateView: View {
    let onFeedback: () -> Void
    @State private var isTargeted = false

    var body: some View {
        ContentUnavailableView {
            Label("No Designs Open", systemImage: "square.grid.2x2")
        } description: {
            Text("Open one or more .dst files (or a Wilcom .emb), or drop them here.")
        } actions: {
            Button("Open…") { Library.shared.presentOpenPanel() }
                .keyboardShortcut("o", modifiers: .command)
            Button("Send App Feedback…") { onFeedback() }
                .buttonStyle(.link)
        }
        .frame(minWidth: 480, minHeight: 320)
        .background(isTargeted ? Color.accentColor.opacity(0.08) : Color.clear)
        .dropDestination(for: URL.self) { urls, _ in
            let accepted = urls.filter { ["dst", "emb"].contains($0.pathExtension.lowercased()) }
            guard !accepted.isEmpty else { return false }
            // This window is registered as empty, so a dropped .dst lands here rather than in
            // a new window. (A .emb opens its own.)
            Library.shared.open(accepted)
            return true
        } isTargeted: { isTargeted = $0 }
    }
}

/// Index or detail, driven by the collection's own navigation path so the state survives
/// the window being redrawn.
struct CollectionView: View {
    @Bindable var collection: DesignCollection

    var body: some View {
        NavigationStack(path: $collection.path) {
            IndexView(collection: collection)
                .navigationDestination(for: OpenDesign.ID.self) { id in
                    if let openDesign = collection.design(id) {
                        DetailView(collection: collection, openDesign: openDesign)
                    } else {
                        ContentUnavailableView("Design Removed", systemImage: "xmark.rectangle")
                    }
                }
        }
        // Read here, so this view re-renders — and the View menu relabels — on navigation.
        .focusedSceneValue(\.visibleViewer, collection.visibleDesign?.model)
        .background(ZoomAliasShortcut(collection: collection))
    }
}
