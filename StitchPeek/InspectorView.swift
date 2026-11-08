import AppKit
import StitchKit
import SwiftUI

extension StitchColor {
    /// SwiftUI's `Color` for a swatch.
    var swiftUIColor: Color { Color(red: red, green: green, blue: blue) }

    /// Reads components back out of whatever the system colour panel produced.
    /// Converting to sRGB first matters: the panel hands back colours in other spaces
    /// (Display P3, greyscale) whose components would otherwise be misread.
    init?(_ color: Color) {
        guard let srgb = NSColor(color).usingColorSpace(.sRGB) else { return nil }
        self.init(
            red: Double(srgb.redComponent),
            green: Double(srgb.greenComponent),
            blue: Double(srgb.blueComponent)
        )
    }
}

/// The stats a person actually wants before hooping something.
struct InspectorView: View {
    let model: ViewerModel
    /// The .dst on disk, for Copy for Agent and the save location.
    var fileURL: URL?

    private var design: Design { model.design }

    var body: some View {
        Form {
            if model.isMarkingUp || !model.annotations.isEmpty {
                MarkupSection(model: model, fileURL: fileURL)
            }

            Section("Design") {
                if let name = design.name {
                    LabeledContent("Name", value: name)
                }
                LabeledContent("Size") {
                    VStack(alignment: .trailing, spacing: 2) {
                        Text(String(format: "%.1f × %.1f mm", design.widthMM, design.heightMM))
                        Text(String(format: "%.2f × %.2f in", design.widthInches, design.heightInches))
                            .foregroundStyle(.secondary)
                    }
                    .font(.system(.body, design: .rounded))
                }
                LabeledContent("Stitches", value: design.stitchCount.formatted())
                LabeledContent("Jumps", value: design.jumpCount.formatted())
                LabeledContent("Trims (est.)", value: design.trimCount.formatted())
                LabeledContent("Color blocks", value: design.blocks.count.formatted())

                if design.isTruncated {
                    Label("File ends without a terminator", systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                        .font(.callout)
                }
                if design.invalidRecordCount > 0 {
                    Label("\(design.invalidRecordCount) unreadable records skipped", systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                        .font(.callout)
                }
                if design.header == nil {
                    Label("Header unreadable — geometry read from stitches", systemImage: "info.circle")
                        .foregroundStyle(.secondary)
                        .font(.callout)
                }
            }

            Section {
                ForEach(Array(design.blocks.enumerated()), id: \.offset) { index, block in
                    BlockRow(
                        model: model,
                        index: index,
                        block: block,
                        isIsolated: model.isolatedBlockIndex == index,
                        isDimmed: model.isolatedBlockIndex != nil && model.isolatedBlockIndex != index
                    )
                }
            } header: {
                HStack {
                    Text("Color Blocks")
                    Spacer()
                    if !model.recoloredBlocks.isEmpty {
                        Button("Reset Colors") { model.resetAllColors() }
                            .buttonStyle(.link)
                            .font(.caption)
                    }
                    if model.isolatedBlockIndex != nil {
                        Button("Show All") { model.isolatedBlockIndex = nil }
                            .buttonStyle(.link)
                            .font(.caption)
                    }
                }
            } footer: {
                // DST stores no color information at all — only "change color here" — so
                // unless the header carried TC entries these come from a fixed palette.
                Text(design.header?.threadColors.isEmpty == false
                     ? "Colors from the file's TC entries. Click a swatch to change one."
                     : "DST files carry no colors, so these come from StitchPeek's palette in stitching order. Click a swatch to change one — it affects this window only and is never written to the file.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

private struct BlockRow: View {
    let model: ViewerModel
    let index: Int
    let block: ColorBlock
    let isIsolated: Bool
    let isDimmed: Bool

    /// Writes straight through to the model so the canvas updates as the colour panel is
    /// dragged, rather than only on dismissal.
    private var binding: Binding<Color> {
        Binding(
            get: { block.color.swiftUIColor },
            set: { newValue in
                if let converted = StitchColor(newValue) {
                    model.setColor(converted, forBlock: index)
                }
            }
        )
    }

    var body: some View {
        HStack(spacing: 10) {
            ColorPicker("Block \(index + 1) color", selection: binding, supportsOpacity: false)
                .labelsHidden()
                .help("Change this block's color")

            VStack(alignment: .leading, spacing: 1) {
                Text(block.color.name ?? "Block \(index + 1)")
                Text("\(block.stitchCount.formatted()) stitches")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            // Only this half toggles isolation; the swatch belongs to the colour picker.
            .contentShape(Rectangle())
            .onTapGesture { model.toggleIsolation(of: index) }

            Spacer()

            if isIsolated {
                Image(systemName: "eye.fill")
                    .foregroundStyle(.tint)
                    .help("Only this block is shown")
            }
        }
        .opacity(isDimmed ? 0.45 : 1)
        .padding(.vertical, 1)
        .contextMenu {
            Button("Reset to Palette Color") { model.resetColor(ofBlock: index) }
                .disabled(!model.recoloredBlocks.contains(index))
            Button(isIsolated ? "Show All Blocks" : "Isolate This Block") {
                model.toggleIsolation(of: index)
            }
        }
    }
}


// MARK: - Markup

private struct MarkupSection: View {
    let model: ViewerModel
    let fileURL: URL?

    @FocusState private var focusedNote: UUID?
    @State private var copied = false

    var body: some View {
        Section {
            if model.markupIsStale {
                VStack(alignment: .leading, spacing: 6) {
                    Label("This design has changed since these marks were made, so they may not line up.",
                          systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                        .font(.callout)
                    HStack {
                        Button("They Still Line Up") { model.confirmMarkupStillLinesUp() }
                        Button("Clear All", role: .destructive) { model.removeAllAnnotations() }
                    }
                    .controlSize(.small)
                }
            }

            if model.annotations.isEmpty {
                Text("Click the design to pin a spot, or drag to box an area. Each mark gets its own note.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            ForEach(Array(model.annotations.enumerated()), id: \.element.id) { index, annotation in
                AnnotationRow(
                    number: index + 1,
                    annotation: annotation,
                    isSelected: model.selectedAnnotationID == annotation.id,
                    note: Binding(
                        get: { annotation.note },
                        set: { model.updateNote(annotation.id, to: $0) }
                    ),
                    focusedNote: $focusedNote,
                    onSelect: { model.selectedAnnotationID = annotation.id },
                    onDelete: { model.removeAnnotation(annotation.id) }
                )
            }

            if let error = model.markupSaveError {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
                    .font(.caption)
            }
        } header: {
            HStack {
                Text("Markup")
                Spacer()
                if !model.annotations.isEmpty {
                    if let fileURL {
                        Button(copied ? "Copied" : "Copy for Agent") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(
                                MarkupStore.agentPrompt(dst: fileURL, annotations: model.annotations),
                                forType: .string
                            )
                            copied = true
                            Task { try? await Task.sleep(for: .seconds(2)); copied = false }
                        }
                        .buttonStyle(.link)
                        .font(.caption)
                        .help("Copy a message for the embroidery agent, with every note and where the files are")
                    }
                    Button("Clear All") { model.removeAllAnnotations() }
                        .buttonStyle(.link)
                        .font(.caption)
                }
            }
        } footer: {
            if let fileURL, !model.annotations.isEmpty {
                Text("Saved beside the design as \(MarkupStore.jsonURL(for: fileURL).lastPathComponent) and \(MarkupStore.pictureURL(for: fileURL).lastPathComponent). Point the embroidery agent at those, or use Copy for Agent.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        // A freshly dropped mark goes straight to its note.
        .onChange(of: model.selectedAnnotationID) { _, id in
            if let id, model.annotations.last?.id == id, model.annotations.last?.note.isEmpty == true {
                focusedNote = id
            }
        }
    }
}

private struct AnnotationRow: View {
    let number: Int
    let annotation: Annotation
    let isSelected: Bool
    @Binding var note: String
    var focusedNote: FocusState<UUID?>.Binding
    let onSelect: () -> Void
    let onDelete: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Text("\(number)")
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 18, height: 18)
                .background(Circle().fill(Color(cgColor: MarkupDrawing.red)))
                .padding(.top, 2)

            VStack(alignment: .leading, spacing: 3) {
                // An empty title plus a prompt: in a grouped Form a titled TextField becomes a
                // labelled row, pushing the note to the trailing edge.
                TextField("", text: $note,
                          prompt: Text(annotation.kind == .pin ? "What needs fixing here?" : "What needs fixing in this area?"),
                          axis: .vertical)
                    .labelsHidden()
                    .multilineTextAlignment(.leading)
                    .lineLimit(1...6)
                    .textFieldStyle(.plain)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .focused(focusedNote, equals: annotation.id)
                Text("\(annotation.kind == .pin ? "Pin" : "Area") · \(annotation.author) · \(annotation.created.formatted(.relative(presentation: .named)))")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 0)

            Button(action: onDelete) {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
            .help("Delete mark \(number)")
        }
        .padding(.vertical, 2)
        .padding(.horizontal, 4)
        .background(isSelected ? Color.accentColor.opacity(0.12) : .clear, in: RoundedRectangle(cornerRadius: 6))
        .contentShape(Rectangle())
        .onTapGesture(perform: onSelect)
    }
}
