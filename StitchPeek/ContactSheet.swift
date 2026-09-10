import AppKit
import CoreGraphics
import ImageIO
import StitchKit
import UniformTypeIdentifiers

/// The index as a printable sheet. Two arrangements, matching the window:
///
/// - **grid** — a contact sheet, twelve designs to a page with name and size under each;
/// - **filmstrip** — one design per row with the full numbers beside it.
///
/// PDF paginates. PNG is a single tall image of the whole batch.
enum ContactSheet {

    struct Item {
        let design: Design
        let displayName: String
        let filename: String
    }

    enum SheetError: LocalizedError {
        case nothingToExport
        case contextUnavailable
        case writeFailed

        var errorDescription: String? {
            switch self {
            case .nothingToExport: return "There are no designs to export."
            case .contextUnavailable: return "Could not create a drawing context for the export."
            case .writeFailed: return "The exported file could not be written."
            }
        }
    }

    // MARK: Geometry

    static let pageWidth: CGFloat = 612            // US Letter
    static let pageHeight: CGFloat = 792
    private static let margin: CGFloat = 36
    private static let headerHeight: CGFloat = 46
    private static let footerHeight: CGFloat = 24
    private static var contentWidth: CGFloat { pageWidth - 2 * margin }
    private static var contentTop: CGFloat { pageHeight - margin - headerHeight }
    private static var contentBottom: CGFloat { margin + footerHeight }

    private static let columns = 3
    private static let gutter: CGFloat = 14
    private static let rowGap: CGFloat = 16
    private static let previewAspect: CGFloat = 0.66
    private static let captionHeight: CGFloat = 26
    private static var cellWidth: CGFloat { ((contentWidth - gutter * CGFloat(columns - 1)) / CGFloat(columns)).rounded(.down) }
    private static var previewHeight: CGFloat { (cellWidth * previewAspect).rounded() }
    private static var cellHeight: CGFloat { previewHeight + 5 + captionHeight }

    private static let stripPreview = CGSize(width: 176, height: 116)
    private static let stripGap: CGFloat = 14

    private static func pitch(for layout: IndexLayout) -> CGFloat {
        switch layout {
        case .grid: return cellHeight + rowGap
        case .filmstrip: return stripPreview.height + stripGap
        }
    }

    private static func itemsPerRow(for layout: IndexLayout) -> Int {
        layout == .grid ? columns : 1
    }

    private static func rowsPerPage(for layout: IndexLayout) -> Int {
        max(1, Int(((contentTop - contentBottom + rowGap) / pitch(for: layout)).rounded(.down)))
    }

    private static func itemsPerPage(for layout: IndexLayout) -> Int {
        rowsPerPage(for: layout) * itemsPerRow(for: layout)
    }

    // MARK: Entry points

    static func writePDF(items: [Item], layout: IndexLayout, title: String, to url: URL) throws {
        guard !items.isEmpty else { throw SheetError.nothingToExport }

        var mediaBox = CGRect(x: 0, y: 0, width: pageWidth, height: pageHeight)
        let info: [String: Any] = [
            kCGPDFContextTitle as String: title,
            kCGPDFContextCreator as String: "StitchPeek"
        ]
        guard let consumer = CGDataConsumer(url: url as CFURL),
              let context = CGContext(consumer: consumer, mediaBox: &mediaBox, info as CFDictionary)
        else { throw SheetError.contextUnavailable }

        let perPage = itemsPerPage(for: layout)
        let pageCount = (items.count + perPage - 1) / perPage
        for page in 0..<pageCount {
            let slice = Array(items[(page * perPage)..<min(items.count, (page + 1) * perPage)])
            context.beginPDFPage(nil)
            draw(
                items: slice,
                allItems: items,
                layout: layout,
                title: title,
                pageNumber: page + 1,
                pageCount: pageCount,
                pageSize: CGSize(width: pageWidth, height: pageHeight),
                into: context
            )
            context.endPDFPage()
        }
        context.closePDF()
    }

    static func writePNG(items: [Item], layout: IndexLayout, title: String, to url: URL) throws {
        guard !items.isEmpty else { throw SheetError.nothingToExport }

        // One page, as tall as the batch needs.
        let rows = (items.count + itemsPerRow(for: layout) - 1) / itemsPerRow(for: layout)
        let height = margin + headerHeight + CGFloat(rows) * pitch(for: layout) - rowGap + footerHeight + margin
        let size = CGSize(width: pageWidth, height: height.rounded(.up))
        let scale: CGFloat = 2

        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(
                data: nil,
                width: Int(size.width * scale),
                height: Int(size.height * scale),
                bitsPerComponent: 8,
                bytesPerRow: 0,
                space: space,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              )
        else { throw SheetError.contextUnavailable }

        context.scaleBy(x: scale, y: scale)
        draw(items: items, allItems: items, layout: layout, title: title,
             pageNumber: 1, pageCount: 1, pageSize: size, into: context)

        guard let image = context.makeImage(),
              let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)
        else { throw SheetError.writeFailed }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw SheetError.writeFailed }
    }

    // MARK: Drawing

    private static func draw(
        items: [Item],
        allItems: [Item],
        layout: IndexLayout,
        title: String,
        pageNumber: Int,
        pageCount: Int,
        pageSize: CGSize,
        into context: CGContext
    ) {
        let previous = NSGraphicsContext.current
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
        defer { NSGraphicsContext.current = previous }

        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(origin: .zero, size: pageSize))

        // Header
        var cursor = pageSize.height - margin
        cursor -= ReportText.draw(title, font: .systemFont(ofSize: 16, weight: .bold), color: .labelColor, topLeft: CGPoint(x: margin, y: cursor))
        cursor -= 3
        let totalStitches = allItems.reduce(0) { $0 + $1.design.stitchCount }
        let stamp = Date().formatted(date: .abbreviated, time: .omitted)
        let summary = "\(allItems.count) design\(allItems.count == 1 ? "" : "s")  ·  \(totalStitches.formatted()) stitches  ·  \(stamp)"
        ReportText.draw(summary, font: .systemFont(ofSize: 9.5), color: .secondaryLabelColor, topLeft: CGPoint(x: margin, y: cursor))

        // Body
        let top = pageSize.height - margin - headerHeight
        switch layout {
        case .grid: drawGrid(items, top: top, into: context)
        case .filmstrip: drawFilmstrip(items, top: top, into: context)
        }

        // Footer
        let ruleY = margin + footerHeight - 6
        context.setStrokeColor(CGColor(gray: 0.85, alpha: 1))
        context.setLineWidth(0.5)
        context.move(to: CGPoint(x: margin, y: ruleY))
        context.addLine(to: CGPoint(x: pageSize.width - margin, y: ruleY))
        context.strokePath()
        ReportText.draw("Generated by StitchPeek", font: .systemFont(ofSize: 8.5), color: .tertiaryLabelColor, topLeft: CGPoint(x: margin, y: ruleY - 5))
        let pageLabel = "Page \(pageNumber) of \(pageCount)"
        let labelWidth = NSAttributedString(string: pageLabel, attributes: [.font: NSFont.systemFont(ofSize: 8.5)]).size().width
        ReportText.draw(pageLabel, font: .systemFont(ofSize: 8.5), color: .tertiaryLabelColor, topLeft: CGPoint(x: pageSize.width - margin - labelWidth, y: ruleY - 5))
    }

    private static func drawGrid(_ items: [Item], top: CGFloat, into context: CGContext) {
        for (index, item) in items.enumerated() {
            let column = index % columns
            let row = index / columns
            let x = margin + CGFloat(column) * (cellWidth + gutter)
            let cellTop = top - CGFloat(row) * pitch(for: .grid)

            let box = CGRect(x: x, y: cellTop - previewHeight, width: cellWidth, height: previewHeight)
            drawPreview(item.design, in: box, into: context)

            var caption = box.minY - 5
            caption -= ReportText.draw(item.displayName, font: .systemFont(ofSize: 9.5, weight: .semibold), color: .labelColor, topLeft: CGPoint(x: x, y: caption), width: cellWidth)
            let stats = String(format: "%.2f × %.2f in  ·  %@ st", item.design.widthInches, item.design.heightInches, item.design.stitchCount.formatted())
            ReportText.draw(stats, font: .systemFont(ofSize: 8.5), color: .secondaryLabelColor, topLeft: CGPoint(x: x, y: caption - 1), width: cellWidth)
        }
    }

    private static func drawFilmstrip(_ items: [Item], top: CGFloat, into context: CGContext) {
        for (index, item) in items.enumerated() {
            let rowTop = top - CGFloat(index) * pitch(for: .filmstrip)
            let box = CGRect(x: margin, y: rowTop - stripPreview.height, width: stripPreview.width, height: stripPreview.height)
            drawPreview(item.design, in: box, into: context)

            let design = item.design
            let textX = box.maxX + 16
            let textWidth = pageWidth - margin - textX
            var cursor = rowTop - 2
            cursor -= ReportText.draw(item.displayName, font: .systemFont(ofSize: 11.5, weight: .semibold), color: .labelColor, topLeft: CGPoint(x: textX, y: cursor), width: textWidth)
            cursor -= 2
            cursor -= ReportText.draw(item.filename, font: .systemFont(ofSize: 8.5), color: .secondaryLabelColor, topLeft: CGPoint(x: textX, y: cursor), width: textWidth)
            cursor -= 6

            let lines = [
                ReportFormat.dimensions(widthInches: design.widthInches, heightInches: design.heightInches, widthMM: design.widthMM, heightMM: design.heightMM),
                "\(design.stitchCount.formatted()) stitches  ·  \(design.blocks.count) color block\(design.blocks.count == 1 ? "" : "s")  ·  \(design.trimCount) trims (est.)",
                "\(ReportFormat.length(mm: design.threadLengthMM)) top thread  ·  \(ReportFormat.length(mm: design.estimatedBobbinLengthMM)) bobbin  ·  \(ReportFormat.duration(design.estimatedRunTime())) at 650 spm (est.)"
            ]
            for line in lines {
                cursor -= ReportText.draw(line, font: .systemFont(ofSize: 9.5), color: .labelColor, topLeft: CGPoint(x: textX, y: cursor), width: textWidth)
                cursor -= 3
            }

            // Colour swatches
            cursor -= 4
            var swatchX = textX
            for block in design.blocks.prefix(16) {
                let swatch = CGRect(x: swatchX, y: cursor - 9, width: 9, height: 9)
                context.setFillColor(DesignRenderer.cgColor(block.color))
                context.fill(swatch)
                context.setStrokeColor(CGColor(gray: 0.75, alpha: 1))
                context.setLineWidth(0.5)
                context.stroke(swatch)
                swatchX += 12
            }
            if design.blocks.count > 16 {
                ReportText.draw("+\(design.blocks.count - 16)", font: .systemFont(ofSize: 8), color: .secondaryLabelColor, topLeft: CGPoint(x: swatchX + 2, y: cursor))
            }

            if index < items.count - 1 {
                let separatorY = rowTop - stripPreview.height - stripGap / 2
                context.setStrokeColor(CGColor(gray: 0.9, alpha: 1))
                context.setLineWidth(0.5)
                context.move(to: CGPoint(x: margin, y: separatorY))
                context.addLine(to: CGPoint(x: pageWidth - margin, y: separatorY))
                context.strokePath()
            }
        }
    }

    private static func drawPreview(_ design: Design, in box: CGRect, into context: CGContext) {
        context.saveGState()
        context.clip(to: box)
        context.translateBy(x: box.minX, y: box.minY)
        var options = DesignRenderer.Options()
        options.drawsBackground = true
        options.drawsBorder = true
        DesignRenderer.render(design, into: context, size: box.size, background: DesignRenderer.fabricColor, options: options)
        context.restoreGState()
    }
}
