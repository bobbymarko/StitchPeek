import StitchKit
import SwiftUI

/// The viewer for one design: canvas, inspector, scrubber. Reached from the index, with
/// previous/next to step through a batch without going back out.
struct DetailView: View {
    let collection: DesignCollection
    let openDesign: OpenDesign
    @State private var showsInspector = true

    /// 60 Hz drive for the stitch scrubber's playback.
    private let tick = Timer.publish(every: 1.0 / 60.0, on: .main, in: .common).autoconnect()

    private var model: ViewerModel { openDesign.model }
    private var position: Int { (collection.index(of: openDesign.id) ?? 0) + 1 }
    private var previous: OpenDesign? { collection.neighbor(of: openDesign.id, offset: -1) }
    private var next: OpenDesign? { collection.neighbor(of: openDesign.id, offset: 1) }

    var body: some View {
        DesignCanvasView(model: model)
            .frame(minWidth: 320, minHeight: 240)
            .safeAreaInset(edge: .bottom, spacing: 0) { scrubber }
            .toolbar { toolbarContent }
            .inspector(isPresented: $showsInspector) {
                InspectorView(model: model)
                    .inspectorColumnWidth(min: 240, ideal: 280, max: 380)
            }
            .navigationTitle(openDesign.displayName)
            .navigationSubtitle(collection.designs.count > 1
                                ? "\(position) of \(collection.designs.count)  ·  \(model.design.stitchCount.formatted()) stitches"
                                : "\(model.design.stitchCount.formatted()) stitches")
            .onReceive(tick) { _ in model.advancePlayback() }
            .background(hiddenShortcuts)
            .id(openDesign.id)      // fresh canvas state when stepping to a neighbour
    }

    // MARK: - Scrubber

    private var scrubber: some View {
        HStack(spacing: 12) {
            Button {
                model.togglePlayback()
            } label: {
                Image(systemName: model.isPlaying ? "pause.fill" : "play.fill")
                    .frame(width: 14)
            }
            .help(model.isPlaying ? "Pause" : "Watch the design stitch out")

            Slider(
                value: Binding(
                    get: { Double(model.stitchesShown) },
                    set: { model.stitchesShown = Int($0) }
                ),
                in: 0...Double(max(model.design.stitchCount, 1))
            )

            Text("\(model.stitchesShown.formatted()) / \(model.design.stitchCount.formatted())")
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.secondary)
                .frame(width: 130, alignment: .trailing)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(.bar)
    }

    // MARK: - Toolbar

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        if collection.designs.count > 1 {
            ToolbarItemGroup(placement: .navigation) {
                Button("Previous", systemImage: "chevron.left") { step(to: previous) }
                    .disabled(previous == nil)
                    .help("Previous design (←)")
                Button("Next", systemImage: "chevron.right") { step(to: next) }
                    .disabled(next == nil)
                    .help("Next design (→)")
            }
        }

        ToolbarItemGroup {
            Button("Fit", systemImage: "arrow.up.left.and.arrow.down.right") { model.fit() }
                .help("Fit to window (⌘0)")

            Button("100%", systemImage: "1.magnifyingglass") { model.actualSize() }
                .help("Actual size — one point per 0.1 mm (⌘1)")

            Text("\(model.zoomPercent)%")
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.secondary)
                .frame(width: 52)

            Toggle(isOn: Binding(get: { model.showsJumps }, set: { model.showsJumps = $0 })) {
                Label("Jumps", systemImage: "arrow.triangle.branch")
            }
            .help("Show jump stitches (J)")

            Menu {
                Button("Export Report as PDF…") { export(.pdf) }
                Button("Export View as PNG…") { export(.png) }
            } label: {
                Label("Export", systemImage: "square.and.arrow.up")
            }
            .help("Export this design (⌘E)")
        }
    }

    private func step(to target: OpenDesign?) {
        guard let target else { return }
        collection.path = [target.id]
    }

    private func export(_ format: Exporter.Format) {
        Exporter.export(
            model: model,
            suggestedName: openDesign.displayName + (format == .pdf ? ".pdf" : ".png"),
            documentName: openDesign.filename,
            format: format
        )
    }

    /// Keyboard shortcuts, parked on zero-sized buttons so they work whenever this window is
    /// key without needing focused-value plumbing up into the app's command menus.
    private var hiddenShortcuts: some View {
        ZStack {
            Button("") { model.fit() }
                .keyboardShortcut("0", modifiers: .command)
            Button("") { model.actualSize() }
                .keyboardShortcut("1", modifiers: .command)
            Button("") { model.showsJumps.toggle() }
                .keyboardShortcut("j", modifiers: [])
            Button("") { export(.pdf) }
                .keyboardShortcut("e", modifiers: .command)
            Button("") { step(to: previous) }
                .keyboardShortcut(.leftArrow, modifiers: [])
            Button("") { step(to: next) }
                .keyboardShortcut(.rightArrow, modifiers: [])
        }
        .opacity(0)
        .frame(width: 0, height: 0)
    }
}
