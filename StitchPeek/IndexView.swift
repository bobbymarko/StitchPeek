import AppKit
import StitchKit
import SwiftUI
import UniformTypeIdentifiers

/// The first screen for a batch: every design as a tile or a filmstrip row. Click one to
/// go into the viewer; the navigation back button returns here.
struct IndexView: View {
    @Bindable var collection: DesignCollection
    @State private var isTargeted = false

    var body: some View {
        content
            .navigationTitle(collection.title)
            .navigationSubtitle(collection.subtitle)
            .toolbar { toolbarContent }
            .background(isTargeted ? Color.accentColor.opacity(0.08) : Color.clear)
            .dropDestination(for: URL.self) { urls, _ in
                Library.shared.add(urls, to: collection)
                return true
            } isTargeted: { isTargeted = $0 }
    }

    @ViewBuilder
    private var content: some View {
        if collection.designs.isEmpty && !collection.isLoading {
            ContentUnavailableView {
                Label("No Designs", systemImage: "square.grid.2x2")
            } description: {
                if collection.failures.isEmpty {
                    Text("Add .dst files to this window, or drop them here.")
                } else {
                    Text("None of the files could be opened.")
                }
            } actions: {
                Button("Add Files…") { Library.shared.presentOpenPanel(addingTo: collection) }
            }
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    if !collection.failures.isEmpty { failureBanner }
                    switch collection.layout {
                    case .grid: grid
                    case .filmstrip: filmstrip
                    }
                }
                .padding(20)
            }
            .overlay {
                if collection.isLoading {
                    ProgressView("Opening designs…")
                        .padding(20)
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
                }
            }
        }
    }

    // MARK: Layouts

    private var grid: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 224, maximum: 224), spacing: 20, alignment: .top)], alignment: .leading, spacing: 24) {
            ForEach(collection.designs) { openDesign in
                Button { open(openDesign) } label: {
                    DesignTile(openDesign: openDesign)
                }
                .buttonStyle(.plain)
                .contextMenu { contextMenu(for: openDesign) }
            }
        }
    }

    private var filmstrip: some View {
        LazyVStack(alignment: .leading, spacing: 0) {
            ForEach(Array(collection.designs.enumerated()), id: \.element.id) { index, openDesign in
                Button { open(openDesign) } label: {
                    FilmstripRow(openDesign: openDesign, position: index + 1, count: collection.designs.count)
                }
                .buttonStyle(.plain)
                .contextMenu { contextMenu(for: openDesign) }
                if index < collection.designs.count - 1 { Divider() }
            }
        }
    }

    private var failureBanner: some View {
        VStack(alignment: .leading, spacing: 4) {
            Label("\(collection.failures.count) file\(collection.failures.count == 1 ? "" : "s") couldn't be opened", systemImage: "exclamationmark.triangle")
                .font(.callout.weight(.medium))
            ForEach(collection.failures) { failure in
                Text("\(failure.url.lastPathComponent) — \(failure.message)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
        .padding(.bottom, 16)
    }

    // MARK: Actions

    private func open(_ openDesign: OpenDesign) {
        collection.path = [openDesign.id]
    }

    @ViewBuilder
    private func contextMenu(for openDesign: OpenDesign) -> some View {
        Button("Open") { open(openDesign) }
        Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([openDesign.url]) }
        Divider()
        Button("Remove from Window") { collection.remove(openDesign.id) }
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItemGroup {
            Picker("Layout", selection: $collection.layout) {
                ForEach(IndexLayout.allCases) { layout in
                    Label(layout.label, systemImage: layout.systemImage).tag(layout)
                }
            }
            .pickerStyle(.segmented)
            .help("Grid or filmstrip")

            Button("Add Files", systemImage: "plus") {
                Library.shared.presentOpenPanel(addingTo: collection)
            }
            .help("Add more designs to this window")

            Menu {
                Button("Export Sheet as PDF…") { exportSheet(.pdf) }
                Button("Export Sheet as PNG…") { exportSheet(.png) }
            } label: {
                Label("Export", systemImage: "square.and.arrow.up")
            }
            .help("Export every design here as one sheet (⌘E)")
            .disabled(collection.designs.isEmpty)
        }
    }

    private func exportSheet(_ format: Exporter.Format) {
        Exporter.exportSheet(
            items: collection.sheetItems,
            layout: collection.layout,
            title: collection.title,
            suggestedName: "\(collection.title) sheet",
            format: format
        )
    }
}

// MARK: - Tiles and rows

/// Renders through the design's cached thumbnail, so scrolling a large batch never
/// re-parses or re-strokes anything.
struct ThumbnailView: View {
    let openDesign: OpenDesign
    let size: CGSize

    var body: some View {
        ZStack {
            Color(cgColor: DesignRenderer.fabricColor)
            if let image = openDesign.thumbnail(size: size, scale: 2) {
                Image(decorative: image, scale: 2)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
            }
        }
        .frame(width: size.width, height: size.height)
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.separator))
    }
}

private struct DesignTile: View {
    let openDesign: OpenDesign

    var body: some View {
        let design = openDesign.design
        VStack(alignment: .leading, spacing: 6) {
            ThumbnailView(openDesign: openDesign, size: CGSize(width: 224, height: 150))
            Text(openDesign.displayName)
                .font(.callout.weight(.medium))
                .lineLimit(1)
            Text(String(format: "%.2f × %.2f in  ·  %@ st", design.widthInches, design.heightInches, design.stitchCount.formatted()))
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .frame(width: 224, alignment: .leading)
        .contentShape(Rectangle())
    }
}

private struct FilmstripRow: View {
    let openDesign: OpenDesign
    let position: Int
    let count: Int

    var body: some View {
        let design = openDesign.design
        HStack(alignment: .top, spacing: 18) {
            ThumbnailView(openDesign: openDesign, size: CGSize(width: 320, height: 200))

            VStack(alignment: .leading, spacing: 5) {
                HStack(alignment: .firstTextBaseline) {
                    Text(openDesign.displayName).font(.title3.weight(.semibold))
                    Spacer()
                    Text("\(position) of \(count)").font(.caption).foregroundStyle(.tertiary)
                }
                Text(openDesign.filename).font(.caption).foregroundStyle(.secondary)

                Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 3) {
                    GridRow {
                        Text("Size").foregroundStyle(.secondary)
                        Text(ReportFormat.dimensions(widthInches: design.widthInches, heightInches: design.heightInches, widthMM: design.widthMM, heightMM: design.heightMM))
                    }
                    GridRow {
                        Text("Stitches").foregroundStyle(.secondary)
                        Text("\(design.stitchCount.formatted())  ·  \(design.blocks.count) color block\(design.blocks.count == 1 ? "" : "s")  ·  \(design.trimCount) trims (est.)")
                    }
                    GridRow {
                        Text("Thread").foregroundStyle(.secondary)
                        Text("\(ReportFormat.length(mm: design.threadLengthMM)) top  ·  \(ReportFormat.length(mm: design.estimatedBobbinLengthMM)) bobbin  ·  \(ReportFormat.duration(design.estimatedRunTime())) (est.)")
                    }
                }
                .font(.callout)
                .padding(.top, 4)

                HStack(spacing: 6) {
                    ForEach(Array(design.blocks.prefix(12).enumerated()), id: \.offset) { _, block in
                        RoundedRectangle(cornerRadius: 3)
                            .fill(block.color.swiftUIColor)
                            .frame(width: 14, height: 14)
                            .overlay(RoundedRectangle(cornerRadius: 3).strokeBorder(.separator))
                    }
                    if design.blocks.count > 12 {
                        Text("+\(design.blocks.count - 12)").font(.caption2).foregroundStyle(.secondary)
                    }
                }
                .padding(.top, 6)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, 14)
        .contentShape(Rectangle())
    }
}
