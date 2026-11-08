import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Reaches the hosting NSWindow for two things SwiftUI on macOS 14 has no API for:
///
/// - switching off state restoration — collections are not persisted, so a window restored
///   from a previous launch would only ever point at nothing (`restorationBehavior` arrived
///   in macOS 15);
/// - closing the window deterministically. `dismissWindow()` proved unreliable for windows
///   that are still being created at launch, and a spurious window that survives is exactly
///   the bug this exists to prevent.
private struct WindowConfigurator: NSViewRepresentable {
    var closes: Bool

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async { apply(to: view) }
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {
        apply(to: view)
    }

    private func apply(to view: NSView) {
        guard let window = view.window else { return }
        window.isRestorable = false
        if closes {
            DispatchQueue.main.async { window.close() }
        }
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
                CollectionView(collection: collection, onFeedback: beginFeedback)
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
                // One empty window is useful — but only when there is nothing else to look at.
                // Nothing in the app creates an empty window on purpose while a batch is open,
                // so a second one is always noise: a window restored from an earlier launch,
                // or the extra window SwiftUI makes at launch alongside the one the batch
                // landed in.
                if library.hasEmptyWindow || library.hasOpenCollections {
                    closeRequested = true
                    return
                }
                library.registerEmptyWindow(token: token) {
                    collectionID = $0.id
                    library.windowDidAppear(for: $0.id)
                }
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
            Text("Open one or more .dst files, or drop them here.")
        } actions: {
            Button("Open…") { Library.shared.presentOpenPanel() }
                .keyboardShortcut("o", modifiers: .command)
            Button("Send Feedback…") { onFeedback() }
                .buttonStyle(.link)
        }
        .frame(minWidth: 480, minHeight: 320)
        .background(isTargeted ? Color.accentColor.opacity(0.08) : Color.clear)
        .dropDestination(for: URL.self) { urls, _ in
            let accepted = urls.filter { $0.pathExtension.lowercased() == "dst" }
            guard !accepted.isEmpty else { return false }
            // This window is registered as empty, so the drop lands here rather than in a
            // new window.
            Library.shared.open(accepted)
            return true
        } isTargeted: { isTargeted = $0 }
    }
}

/// Index or detail, driven by the collection's own navigation path so the state survives
/// the window being redrawn.
struct CollectionView: View {
    @Bindable var collection: DesignCollection
    let onFeedback: () -> Void

    var body: some View {
        NavigationStack(path: $collection.path) {
            IndexView(collection: collection, onFeedback: onFeedback)
                .navigationDestination(for: OpenDesign.ID.self) { id in
                    if let openDesign = collection.design(id) {
                        DetailView(collection: collection, openDesign: openDesign, onFeedback: onFeedback)
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
