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

    private var design: Design { model.design }

    var body: some View {
        Form {
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
