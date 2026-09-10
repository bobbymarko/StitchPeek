import AppKit
import CoreGraphics
import StitchKit

/// Lays out the one-page PDF report: a preview of the design over a table of the numbers
/// you want before hooping something.
///
/// Everything here is drawn into a plain `CGContext`, so the same code would serve a
/// multi-page report or a print job later.
enum PDFReport {

    // US Letter, in points.
    static let pageSize = CGSize(width: 612, height: 792)
    private static let margin: CGFloat = 54          // 0.75"
    private static let rowHeight: CGFloat = 21
    private static let blockRowHeight: CGFloat = 20
    private static let titleHeight: CGFloat = 16
    /// Everything must finish above this line, which leaves room for the footer rule
    /// and its caption.
    private static var contentBottom: CGFloat { margin + 34 }
    private static let previewHeightRange: ClosedRange<CGFloat> = 90...320
    private static let moreLineHeight: CGFloat = 14

    private static var contentWidth: CGFloat { pageSize.width - 2 * margin }

    /// Estimates are labelled as such rather than presented as fact — DST records none of
    /// them, they are derived from the stitch geometry.
    private static let stitchesPerMinute: Double = 650

    static func draw(
        design: Design,
        filename: String,
        options: DesignRenderer.Options,
        into context: CGContext
    ) {
        let previous = NSGraphicsContext.current
        // flipped: false — the PDF context is y-up, and so is AppKit text drawing here.
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
        defer { NSGraphicsContext.current = previous }

        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(origin: .zero, size: pageSize))

        var cursor = pageSize.height - margin        // descends down the page

        cursor = drawHeader(filename: filename, design: design, at: cursor)
        cursor -= 26
        cursor = drawSectionTitle("Design Preview", at: cursor)
        cursor -= 12

        // Solve the page before drawing any of it. The details table is fixed, so whatever
        // is left over is shared between the preview and the block list: the preview gets
        // what it can up to its cap, and the block list is truncated to what still fits.
        // Without this the table simply ran over the footer.
        let rows = detailRows(design: design, filename: filename)
        let showsBlocks = design.blocks.count > 1

        let detailsBlock = 30 + titleHeight + 10 + CGFloat(rows.count) * rowHeight
        let blocksHeader: CGFloat = showsBlocks ? 24 + titleHeight + 10 : 0
        let shared = cursor - contentBottom - detailsBlock - blocksHeader

        let blocksWanted = showsBlocks ? CGFloat(design.blocks.count) * blockRowHeight : 0
        let previewHeight = min(
            max(shared - blocksWanted, previewHeightRange.lowerBound),
            previewHeightRange.upperBound
        )

        var listedBlocks = design.blocks.count
        if showsBlocks {
            let blocksSpace = shared - previewHeight
            var fits = Int(floor(blocksSpace / blockRowHeight))
            if fits < design.blocks.count {
                // Truncating costs a "+ n more" line, which itself needs room.
                fits = Int(floor((blocksSpace - moreLineHeight) / blockRowHeight))
            }
            listedBlocks = max(0, min(design.blocks.count, fits))
        }

        cursor = drawPreview(design: design, options: options, height: previewHeight, at: cursor, into: context)
        cursor -= 30
        cursor = drawSectionTitle("Design Details", at: cursor)
        cursor -= 10
        cursor = drawDetails(rows: rows, at: cursor, into: context)

        if showsBlocks {
            cursor -= 24
            cursor = drawSectionTitle("Color Blocks", at: cursor)
            cursor -= 10
            cursor = drawColorBlocks(design: design, limit: listedBlocks, at: cursor, into: context)
        }

        drawFooter(into: context)
    }

    // MARK: - Sections

    private static func drawHeader(filename: String, design: Design, at top: CGFloat) -> CGFloat {
        var cursor = top
        cursor -= ReportText.draw(
            "Design Report",
            font: .systemFont(ofSize: 22, weight: .bold),
            color: .labelColor,
            topLeft: CGPoint(x: margin, y: cursor)
        )
        cursor -= 4

        var subtitle = "File: \(filename)"
        if let name = design.name { subtitle += "  ·  \(name)" }
        cursor -= ReportText.draw(
            subtitle,
            font: .systemFont(ofSize: 10),
            color: .secondaryLabelColor,
            topLeft: CGPoint(x: margin, y: cursor)
        )
        return cursor
    }

    private static func drawSectionTitle(_ title: String, at top: CGFloat) -> CGFloat {
        top - ReportText.draw(
            title,
            font: .systemFont(ofSize: 13, weight: .semibold),
            color: .labelColor,
            topLeft: CGPoint(x: margin, y: top)
        )
    }

    private static func drawPreview(
        design: Design,
        options: DesignRenderer.Options,
        height: CGFloat,
        at top: CGFloat,
        into context: CGContext
    ) -> CGFloat {
        let box = CGRect(x: margin, y: top - height, width: contentWidth, height: height)

        context.saveGState()
        context.clip(to: box)
        context.translateBy(x: box.minX, y: box.minY)

        // The whole design, framed to the box — a report of a zoomed-in crop would be no
        // use. The viewer's toggles (isolated block, jump overlay, stitch limit) are kept.
        var previewOptions = options
        previewOptions.transform = nil               // fall back to the automatic fit
        previewOptions.drawsBackground = true
        previewOptions.drawsBorder = true
        DesignRenderer.render(
            design,
            into: context,
            size: box.size,
            background: DesignRenderer.fabricColor,
            options: previewOptions
        )
        context.restoreGState()

        return box.minY
    }

    private static func drawDetails(
        rows: [(label: String, value: String)],
        at top: CGFloat,
        into context: CGContext
    ) -> CGFloat {
        var cursor = top
        for (index, row) in rows.enumerated() {
            cursor = drawRow(row.label, row.value, at: cursor, shaded: index.isMultiple(of: 2), into: context)
        }
        return cursor
    }

    private static func detailRows(design: Design, filename: String) -> [(label: String, value: String)] {
        var rows: [(String, String)] = [
            ("File", filename),
            ("Width", String(format: "%.2f\" (%.0f mm)", design.widthInches, design.widthMM)),
            ("Height", String(format: "%.2f\" (%.0f mm)", design.heightInches, design.heightMM)),
            ("Stitches", design.stitchCount.formatted()),
            ("Color blocks", design.blocks.count.formatted()),
            ("Color changes", design.colorChangeCount.formatted()),
            ("Jumps", design.jumpCount.formatted()),
            // DST has no trim command; three or more consecutive jumps conventionally means one.
            ("Trims (est.)", design.trimCount.formatted()),
            ("Thread (est.)", ReportFormat.length(mm: design.threadLengthMM)),
            ("Bobbin thread (est.)", ReportFormat.length(mm: design.estimatedBobbinLengthMM)),
            ("Run time (est. @ \(Int(stitchesPerMinute)) spm)",
             ReportFormat.duration(design.estimatedRunTime(stitchesPerMinute: stitchesPerMinute)))
        ]
        if design.isTruncated {
            rows.append(("Note", "File ends without a terminator"))
        }
        if design.invalidRecordCount > 0 {
            rows.append(("Note", "\(design.invalidRecordCount) unreadable records skipped"))
        }
        return rows.map { (label: $0.0, value: $0.1) }
    }

    private static func drawColorBlocks(
        design: Design,
        limit: Int,
        at top: CGFloat,
        into context: CGContext
    ) -> CGFloat {
        var cursor = top
        for (index, block) in design.blocks.prefix(limit).enumerated() {
            let rect = CGRect(x: margin, y: cursor - blockRowHeight, width: contentWidth, height: blockRowHeight)
            if index.isMultiple(of: 2) {
                context.setFillColor(CGColor(gray: 0.968, alpha: 1))
                context.fill(rect)
            }

            let swatch = CGRect(x: margin + 8, y: rect.midY - 5, width: 10, height: 10)
            context.setFillColor(DesignRenderer.cgColor(block.color))
            context.fill(swatch)
            context.setStrokeColor(CGColor(gray: 0.75, alpha: 1))
            context.setLineWidth(0.5)
            context.stroke(swatch)

            let label = block.color.name.map { "\(index + 1). \($0)" } ?? "Block \(index + 1)"
            _ = ReportText.draw(
                label,
                font: .systemFont(ofSize: 9.5),
                color: .labelColor,
                topLeft: CGPoint(x: margin + 26, y: rect.maxY - 5)
            )
            _ = ReportText.draw(
                "\(block.stitchCount.formatted()) stitches  ·  \(block.color.hexString)  ·  \(ReportFormat.length(mm: block.threadLengthMM))",
                font: .systemFont(ofSize: 9.5),
                color: .secondaryLabelColor,
                topLeft: CGPoint(x: margin + 210, y: rect.maxY - 5)
            )
            cursor = rect.minY
        }
        if design.blocks.count > limit {
            cursor -= ReportText.draw(
                "+ \(design.blocks.count - limit) more blocks",
                font: .systemFont(ofSize: 9),
                color: .tertiaryLabelColor,
                topLeft: CGPoint(x: margin + 26, y: cursor - 3)
            ) + 5
        }
        return cursor
    }

    private static func drawRow(
        _ label: String,
        _ value: String,
        at top: CGFloat,
        shaded: Bool,
        into context: CGContext
    ) -> CGFloat {
        let rect = CGRect(x: margin, y: top - rowHeight, width: contentWidth, height: rowHeight)

        if shaded {
            context.setFillColor(CGColor(gray: 0.968, alpha: 1))
            context.fill(rect)
        }

        _ = ReportText.draw(
            label,
            font: .systemFont(ofSize: 10),
            color: .secondaryLabelColor,
            topLeft: CGPoint(x: rect.minX + 12, y: rect.maxY - 5)
        )
        _ = ReportText.draw(
            value,
            font: .systemFont(ofSize: 10, weight: .semibold),
            color: .labelColor,
            topLeft: CGPoint(x: rect.minX + 210, y: rect.maxY - 5)
        )
        return rect.minY
    }

    private static func drawFooter(into context: CGContext) {
        let y = margin + 22
        context.setStrokeColor(CGColor(gray: 0.85, alpha: 1))
        context.setLineWidth(0.5)
        context.move(to: CGPoint(x: margin, y: y))
        context.addLine(to: CGPoint(x: pageSize.width - margin, y: y))
        context.strokePath()

        let stamp = Date().formatted(date: .abbreviated, time: .shortened)
        _ = ReportText.draw(
            "Generated by StitchPeek  ·  \(stamp)",
            font: .systemFont(ofSize: 8.5),
            color: .tertiaryLabelColor,
            topLeft: CGPoint(x: margin, y: y - 6)
        )
    }
}
