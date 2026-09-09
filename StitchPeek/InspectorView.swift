import StitchKit
import SwiftUI

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
                        index: index,
                        block: block,
                        isIsolated: model.isolatedBlockIndex == index,
                        isDimmed: model.isolatedBlockIndex != nil && model.isolatedBlockIndex != index
                    )
                    .contentShape(Rectangle())
                    .onTapGesture { model.toggleIsolation(of: index) }
                }
            } header: {
                HStack {
                    Text("Color Blocks")
                    Spacer()
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
                     ? "Colors from the file's TC entries."
                     : "DST files carry no colors. These are StitchPeek's palette, assigned in stitching order.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

private struct BlockRow: View {
    let index: Int
    let block: ColorBlock
    let isIsolated: Bool
    let isDimmed: Bool

    var body: some View {
        HStack(spacing: 10) {
            RoundedRectangle(cornerRadius: 3)
                .fill(Color(red: block.color.red, green: block.color.green, blue: block.color.blue))
                .frame(width: 16, height: 16)
                .overlay(RoundedRectangle(cornerRadius: 3).strokeBorder(.separator))

            VStack(alignment: .leading, spacing: 1) {
                Text(block.color.name ?? "Block \(index + 1)")
                Text("\(block.stitchCount.formatted()) stitches")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            if isIsolated {
                Image(systemName: "eye.fill")
                    .foregroundStyle(.tint)
                    .help("Only this block is shown")
            }
        }
        .opacity(isDimmed ? 0.45 : 1)
        .padding(.vertical, 1)
    }
}
