import AppKit
import Observation
import StitchKit
import UniformTypeIdentifiers

extension UTType {
    /// Declared in the host app's Info.plist under `UTExportedTypeDeclarations`.
    static let tajimaDST = UTType(exportedAs: "com.bobbymarko.stitchpeek.tajima-dst")
    /// Embrilliance's identifier for the same format, imported in Info.plist. On a machine
    /// where Embrilliance is installed this is the type a .dst actually resolves to.
    static let embrillianceDST = UTType(importedAs: "com.britonleap.dst")
    static var dstTypes: [UTType] { [.tajimaDST, .embrillianceDST] }
}

enum IndexLayout: String, CaseIterable, Identifiable {
    case grid
    case filmstrip

    var id: String { rawValue }

    var label: String {
        switch self {
        case .grid: return "Grid"
        case .filmstrip: return "Filmstrip"
        }
    }

    var systemImage: String {
        switch self {
        case .grid: return "square.grid.2x2"
        case .filmstrip: return "rectangle.grid.1x2"
        }
    }
}

// MARK: - One open design

/// A design open in a window, with its viewer state. Recolours live in the model, so they
/// survive going back to the index and into the design again, and the index thumbnail
/// reflects them.
@MainActor
@Observable
final class OpenDesign: Identifiable {
    let id = UUID()
    let url: URL
    let model: ViewerModel

    var filename: String { url.lastPathComponent }
    var displayName: String { url.deletingPathExtension().lastPathComponent }
    var design: Design { model.design }

    init(url: URL, design: Design) {
        self.url = url
        self.model = ViewerModel(design: design)
    }

    private struct ThumbnailKey: Equatable {
        var width: Int
        var height: Int
        var colorVersion: Int
    }

    // Not observed: it is filled in from inside a view body, and an observed write there
    // would schedule another body evaluation.
    @ObservationIgnored private var cachedThumbnail: (key: ThumbnailKey, image: CGImage)?

    /// A rendered thumbnail at `size` points, cached until the size or colours change.
    /// Draws the model's interaction copy, which is decimated for very large designs and
    /// carries the current recolours.
    func thumbnail(size: CGSize, scale: CGFloat) -> CGImage? {
        let key = ThumbnailKey(
            width: Int(size.width * scale),
            height: Int(size.height * scale),
            colorVersion: model.colorVersion
        )
        if let cachedThumbnail, cachedThumbnail.key == key { return cachedThumbnail.image }

        var options = DesignRenderer.Options()
        options.drawsBorder = false
        guard let image = DesignRenderer.image(model.interactiveDesign, size: size, scale: scale, options: options) else {
            return nil
        }
        cachedThumbnail = (key, image)
        return image
    }
}

// MARK: - A window's worth of designs

/// Everything one window shows: the designs from one open action, which layout the index
/// is in, and how far into a design the window has navigated.
@MainActor
@Observable
final class DesignCollection: Identifiable {
    let id = UUID()
    var designs: [OpenDesign] = []
    var failures: [LoadFailure] = []
    var layout: IndexLayout = .grid
    /// Navigation: empty shows the index; one id shows that design.
    var path: [OpenDesign.ID] = []
    var isLoading = false

    struct LoadFailure: Identifiable {
        let id = UUID()
        let url: URL
        let message: String
    }

    /// The folder the designs came from, when they share one — for a batch that is
    /// usually the order name. A single design is titled by its own name.
    var title: String {
        if designs.count == 1, let only = designs.first { return only.displayName }
        let folders = Set(designs.map { $0.url.deletingLastPathComponent() })
        if folders.count == 1, let folder = folders.first { return folder.lastPathComponent }
        return "Designs"
    }

    var subtitle: String {
        guard !designs.isEmpty else { return "" }
        return "\(designs.count) design\(designs.count == 1 ? "" : "s")  ·  \(totalStitches.formatted()) stitches"
    }

    var totalStitches: Int { designs.reduce(0) { $0 + $1.design.stitchCount } }

    func design(_ id: OpenDesign.ID) -> OpenDesign? {
        designs.first { $0.id == id }
    }

    func index(of id: OpenDesign.ID) -> Int? {
        designs.firstIndex { $0.id == id }
    }

    func neighbor(of id: OpenDesign.ID, offset: Int) -> OpenDesign? {
        guard let index = index(of: id) else { return nil }
        let target = index + offset
        return designs.indices.contains(target) ? designs[target] : nil
    }

    func remove(_ id: OpenDesign.ID) {
        designs.removeAll { $0.id == id }
        path.removeAll { $0 == id }
    }

    /// Snapshot for the exporters, which draw without touching observable state.
    var sheetItems: [ContactSheet.Item] {
        designs.map { ContactSheet.Item(design: $0.design, displayName: $0.displayName, filename: $0.filename) }
    }
}

// MARK: - The library

/// Owns every open collection and routes newly opened files to windows.
///
/// The model is Preview.app's: each open action — a Finder double-click on a selection,
/// the open panel, a drop — becomes one window holding that batch. An empty window that is
/// already showing is reused rather than left behind.
@MainActor
@Observable
final class Library {
    static let shared = Library()

    private(set) var collections: [UUID: DesignCollection] = [:]

    /// Set by the first window to appear; `WindowGroup` only hands this action to views.
    @ObservationIgnored var openWindow: (@MainActor (UUID) -> Void)?

    /// Collections that arrived before any window could take them (launch by double-click).
    @ObservationIgnored private var pending: [DesignCollection] = []
    /// Empty windows waiting for content, keyed by a per-window token.
    @ObservationIgnored private var adopters: [UUID: @MainActor (DesignCollection) -> Void] = [:]
    /// Collections whose window has actually appeared — the check behind `requestWindow`.
    @ObservationIgnored private var appeared: Set<UUID> = []

    private init() {}

    func collection(_ id: UUID) -> DesignCollection? { collections[id] }

    /// True while some window is showing the empty state and waiting for a batch.
    var hasEmptyWindow: Bool { !adopters.isEmpty }
    /// True while any window is showing a batch.
    var hasOpenCollections: Bool { !collections.isEmpty }

    func forget(_ id: UUID) { collections[id] = nil }

    // MARK: Opening

    /// The single entry point for every way files arrive. One window per call.
    func open(_ urls: [URL]) {
        let accepted = urls.filter { $0.pathExtension.lowercased() == "dst" }
        guard !accepted.isEmpty else { return }
        let collection = DesignCollection()
        collections[collection.id] = collection
        load(accepted, into: collection)
        place(collection)
    }

    func add(_ urls: [URL], to collection: DesignCollection) {
        let accepted = urls.filter { $0.pathExtension.lowercased() == "dst" }
        guard !accepted.isEmpty else { return }
        load(accepted, into: collection)
    }

    func presentOpenPanel(addingTo collection: DesignCollection? = nil) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = UTType.dstTypes
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.message = collection == nil ? "Choose one or more DST designs." : "Choose designs to add to this window."
        panel.begin { response in
            guard response == .OK else { return }
            if let collection {
                self.add(panel.urls, to: collection)
            } else {
                self.open(panel.urls)
            }
        }
    }

    // MARK: Window placement

    private func place(_ collection: DesignCollection) {
        if let (token, adopt) = adopters.first {
            adopters[token] = nil
            adopt(collection)
        } else if openWindow != nil {
            requestWindow(for: collection)
        } else {
            pending.append(collection)
        }
    }

    /// Opens a window for `collection` — exactly once. `openWindow` is never re-issued for
    /// the same batch: SwiftUI does not reliably dedupe a `WindowGroup(for:)` value while its
    /// first window is still being created, and a retry produced a duplicate window in
    /// testing. If the window has not appeared after a generous wait (an `openWindow` issued
    /// while the scene system is still starting up can be dropped), the batch goes back to
    /// `pending`, where the next empty window picks it up.
    private func requestWindow(for collection: DesignCollection) {
        openWindow?(collection.id)
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard let self,
                  self.collections[collection.id] != nil,
                  !self.appeared.contains(collection.id),
                  !self.pending.contains(where: { $0.id == collection.id })
            else { return }
            self.pending.append(collection)
        }
    }

    /// Called once `openWindow` is available: show every batch that arrived before it was.
    func flushPending() {
        guard openWindow != nil, !pending.isEmpty else { return }
        let waiting = pending
        pending.removeAll()
        for collection in waiting { requestWindow(for: collection) }
    }

    func windowDidAppear(for id: UUID) {
        appeared.insert(id)
    }

    /// A batch that arrived before any window could show it — the launch-by-double-click
    /// case, where the delegate runs before SwiftUI has made a window.
    func takePending() -> DesignCollection? {
        pending.isEmpty ? nil : pending.removeFirst()
    }

    /// An empty window announces itself and waits for the next batch.
    func registerEmptyWindow(token: UUID, adopt: @escaping @MainActor (DesignCollection) -> Void) {
        adopters[token] = adopt
    }

    func unregisterEmptyWindow(token: UUID) {
        adopters[token] = nil
    }

    // MARK: Loading

    private func load(_ urls: [URL], into collection: DesignCollection) {
        let wasEmpty = collection.designs.isEmpty
        collection.isLoading = true

        Task {
            // Parse off the main thread, concurrently, then rebuild the original order so a
            // batch shows up the way Finder had it sorted.
            let results = await withTaskGroup(of: (Int, Result<Design, any Error>).self) { group in
                for (index, url) in urls.enumerated() {
                    group.addTask {
                        // Recent-documents URLs from an earlier launch carry a security scope
                        // that has to be opened; everything else returns false harmlessly.
                        let scoped = url.startAccessingSecurityScopedResource()
                        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                        return (index, Result { try DSTParser.parse(contentsOf: url) })
                    }
                }
                var collected: [(Int, Result<Design, any Error>)] = []
                for await result in group { collected.append(result) }
                return collected.sorted { $0.0 < $1.0 }
            }

            for (index, result) in results {
                let url = urls[index]
                switch result {
                case .success(let design):
                    collection.designs.append(OpenDesign(url: url, design: design))
                    RecentDocuments.shared.note(url)
                case .failure(let error):
                    collection.failures.append(.init(url: url, message: error.localizedDescription))
                }
            }
            collection.isLoading = false

            // A single design goes straight to the detail view; a grid of one is a detour.
            if wasEmpty, collection.designs.count == 1, collection.path.isEmpty, let only = collection.designs.first {
                collection.path = [only.id]
            }
        }
    }
}
