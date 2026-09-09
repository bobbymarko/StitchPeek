import StitchKit
import SwiftUI

struct DocumentView: View {
    @State private var model: ViewerModel
    @State private var showsInspector = true
    private let fileURL: URL?

    /// 60 Hz drive for the stitch scrubber's playback.
    private let tick = Timer.publish(every: 1.0 / 60.0, on: .main, in: .common).autoconnect()

    init(document: DesignDocument, fileURL: URL?) {
        _model = State(initialValue: ViewerModel(design: document.design))
        self.fileURL = fileURL
    }

    private var baseName: String {
        fileURL?.deletingPathExtension().lastPathComponent
            ?? model.design.name
            ?? "Design"
    }

    var body: some View {
        DesignCanvasView(model: model)
            .frame(minWidth: 320, minHeight: 240)
            .safeAreaInset(edge: .bottom, spacing: 0) { scrubber }
            .toolbar { toolbarContent }
            .inspector(isPresented: $showsInspector) {
                InspectorView(model: model)
                    .inspectorColumnWidth(min: 240, ideal: 280, max: 380)
            }
            .navigationTitle(baseName)
            .onReceive(tick) { _ in model.advancePlayback() }
            .background(hiddenShortcuts)
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
                Button("Export as PDF…") {
                    Exporter.export(model: model, suggestedName: baseName + ".pdf", format: .pdf)
                }
                Button("Export as PNG…") {
                    Exporter.export(model: model, suggestedName: baseName + ".png", format: .png)
                }
            } label: {
                Label("Export", systemImage: "square.and.arrow.up")
            }
            .help("Export the current view (⌘E)")
        }
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
            Button("") {
                Exporter.export(model: model, suggestedName: baseName + ".pdf", format: .pdf)
            }
            .keyboardShortcut("e", modifiers: .command)
        }
        .opacity(0)
        .frame(width: 0, height: 0)
    }
}
