import SwiftUI

// MARK: - What the key window publishes to the menu bar

/// The batch shown in the key window.
struct ActiveCollectionKey: FocusedValueKey {
    typealias Value = DesignCollection
}

/// The design open in the key window's viewer, when it is on the viewer rather than the
/// index. Published separately from the collection so the menu re-renders when you
/// navigate in or out.
struct VisibleViewerKey: FocusedValueKey {
    typealias Value = ViewerModel
}

/// Opens the feedback sheet on the key window.
struct FeedbackAction {
    let perform: () -> Void
}

struct FeedbackActionKey: FocusedValueKey {
    typealias Value = FeedbackAction
}

extension FocusedValues {
    var activeCollection: DesignCollection? {
        get { self[ActiveCollectionKey.self] }
        set { self[ActiveCollectionKey.self] = newValue }
    }

    var visibleViewer: ViewerModel? {
        get { self[VisibleViewerKey.self] }
        set { self[VisibleViewerKey.self] = newValue }
    }

    var feedbackAction: FeedbackAction? {
        get { self[FeedbackActionKey.self] }
        set { self[FeedbackActionKey.self] = newValue }
    }
}

// MARK: - View menu

/// Zoom lives in the View menu, where people look for it. In the viewer it zooms the
/// canvas; on the index it resizes the tiles, the way Finder and Photos do.
///
/// ⌘= is handled too (see `ZoomAliasShortcut`): most people press ⌘= for zoom in, and a
/// menu item can only own one key equivalent.
struct ViewCommands: Commands {
    @FocusedValue(\.activeCollection) private var collection
    @FocusedValue(\.visibleViewer) private var viewer

    var body: some Commands {
        CommandGroup(before: .toolbar) {
            Button("Zoom In") { zoomIn() }
                .keyboardShortcut("+", modifiers: .command)
                .disabled(collection == nil)

            Button("Zoom Out") { zoomOut() }
                .keyboardShortcut("-", modifiers: .command)
                .disabled(collection == nil)

            Button(viewer == nil ? "Default Tile Size" : "Zoom to Fit") {
                if let viewer { viewer.fit() } else { collection?.tileScale = 1 }
            }
            .keyboardShortcut("0", modifiers: .command)
            .disabled(collection == nil)

            Button("Actual Size") { viewer?.actualSize() }
                .keyboardShortcut("1", modifiers: .command)
                .disabled(viewer == nil)

            Divider()

            // No key equivalent here on purpose: an app-wide plain "J" would fire while
            // typing into the feedback sheet. The viewer handles J itself.
            Toggle("Show Jump Stitches", isOn: Binding(
                get: { viewer?.showsJumps ?? false },
                set: { viewer?.showsJumps = $0 }
            ))
            .disabled(viewer == nil)

            Divider()
        }
    }

    private func zoomIn() {
        if let viewer { viewer.zoomIn() } else { collection?.enlargeTiles() }
    }

    private func zoomOut() {
        if let viewer { viewer.zoomOut() } else { collection?.shrinkTiles() }
    }
}

/// ⌘= as a second key for Zoom In, scoped to the window.
struct ZoomAliasShortcut: View {
    let collection: DesignCollection

    var body: some View {
        Button("") {
            if let viewer = collection.visibleDesign?.model {
                viewer.zoomIn()
            } else {
                collection.enlargeTiles()
            }
        }
        .keyboardShortcut("=", modifiers: .command)
        .opacity(0)
        .frame(width: 0, height: 0)
        .accessibilityHidden(true)
    }
}

// MARK: - App and Help menus

struct AppMenuCommands: Commands {
    @FocusedValue(\.feedbackAction) private var feedbackAction

    var body: some Commands {
        CommandGroup(after: .appInfo) {
            Button("Check for Updates…") { Updater.shared.checkNow() }
        }

        CommandGroup(replacing: .help) {
            Button("Send Feedback…") { feedbackAction?.perform() }
                .keyboardShortcut("f", modifiers: [.command, .shift])
                .disabled(feedbackAction == nil)
            Divider()
            Button("StitchPeek on GitHub") {
                if let url = URL(string: "https://github.com/\(Updater.repository)") {
                    NSWorkspace.shared.open(url)
                }
            }
        }
    }
}
