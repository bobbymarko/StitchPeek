import CoreGraphics
import CoreText
import Foundation
import ImageIO

/// Turns an `EMBDesign` into pictures: the picture inside the file, and an info panel of the
/// kind the DST previews do not need.
///
/// There is no stitch geometry to draw (see `EMBDesign`), so the image is Wilcom's own render
/// stored in the file.
public enum EMBRenderer {

    /// Size of the Quick Look preview canvas: the picture on the left, the info panel on the right.
    public static let previewSize = CGSize(width: 960, height: 600)

    // MARK: Image

    /// The best embedded picture, decoded and trimmed: the 256 px TrueView render, else the
    /// 100 px icon.
    public static func previewImage(for design: EMBDesign) -> CGImage? {
        for data in [design.trueViewJPEG, design.designIconBMP] {
            guard let data, let source = CGImageSourceCreateWithData(data as CFData, nil),
                  let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
            else { continue }
            return trimmed(image)
        }
        return nil
    }

    /// Wilcom renders the design into a square and pads the short side with flat grey (221).
    /// Crop that off, so a wide design is not a thin strip inside a square. Only done when the
    /// top-left pixel is that grey; a design that fills the square has nothing to trim.
    static func trimmed(_ image: CGImage) -> CGImage {
        let w = image.width, h = image.height
        guard w >= 16, h >= 16 else { return image }
        var pixels = [UInt8](repeating: 0, count: w * h * 4)
        let drawn = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(
                data: buffer.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        guard drawn else { return image }

        let r0 = Int(pixels[0]), g0 = Int(pixels[1]), b0 = Int(pixels[2])
        guard (212...230).contains(r0), abs(r0 - g0) <= 4, abs(r0 - b0) <= 4 else { return image }

        func isContent(_ x: Int, _ y: Int) -> Bool {
            let o = (y * w + x) * 4
            return abs(Int(pixels[o]) - r0) + abs(Int(pixels[o + 1]) - g0) + abs(Int(pixels[o + 2]) - b0) > 12
        }
        var top = h, bottom = -1, left = w, right = -1
        for y in 0..<h {
            for x in 0..<w where isContent(x, y) {
                top = min(top, y); bottom = max(bottom, y)
                left = min(left, x); right = max(right, x)
            }
        }
        guard bottom - top >= 7, right - left >= 7 else { return image }
        let rect = CGRect(x: left, y: top, width: right - left + 1, height: bottom - top + 1)
        return image.cropping(to: rect) ?? image
    }

    /// The largest size with `image`'s aspect ratio that fits inside `max`.
    public static func fittedSize(for image: CGImage, max maxSize: CGSize) -> CGSize {
        let w = CGFloat(image.width), h = CGFloat(image.height)
        guard w > 0, h > 0, maxSize.width > 0, maxSize.height > 0 else { return maxSize }
        let scale = Swift.min(maxSize.width / w, maxSize.height / h)
        return CGSize(width: Swift.max(1, (w * scale).rounded()), height: Swift.max(1, (h * scale).rounded()))
    }

    // MARK: Thumbnail

    /// Just the picture, filling the context.
    public static func renderThumbnail(_ image: CGImage, into context: CGContext, size: CGSize) {
        context.saveGState()
        defer { context.restoreGState() }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(origin: .zero, size: size))
    }

    // MARK: Preview

    /// Picture on the left; on the right the file name, the design facts, and a swatch per thread.
    /// `context` is y-up, like every other renderer here.
    public static func renderPreview(
        _ design: EMBDesign, image: CGImage?, title: String, into context: CGContext, size: CGSize
    ) {
        context.saveGState()
        defer { context.restoreGState() }
        context.textMatrix = .identity

        let fabric = DesignRenderer.fabricColor
        let border = CGColor(
            srgbRed: DesignRenderer.borderComponents.red, green: DesignRenderer.borderComponents.green,
            blue: DesignRenderer.borderComponents.blue, alpha: 1
        )
        let ink = CGColor(srgbRed: 0.13, green: 0.13, blue: 0.14, alpha: 1)
        let muted = CGColor(srgbRed: 0.42, green: 0.42, blue: 0.44, alpha: 1)

        context.setFillColor(fabric)
        context.fill(CGRect(origin: .zero, size: size))

        // Left: the picture, in a square of its own.
        let pane = size.height
        let inset: CGFloat = 36
        if let image {
            context.interpolationQuality = .high
            let box = CGRect(x: inset, y: inset, width: pane - 2 * inset, height: pane - 2 * inset)
            let fit = fittedSize(for: image, max: box.size)
            let rect = CGRect(
                x: box.midX - fit.width / 2, y: box.midY - fit.height / 2, width: fit.width, height: fit.height
            )
            context.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1))
            context.fill(rect)
            context.draw(image, in: rect)
            context.setStrokeColor(border)
            context.setLineWidth(1)
            context.stroke(rect.insetBy(dx: -0.5, dy: -0.5))
        }

        // Right: the facts.
        let x = pane + 8
        let width = size.width - x - 36
        var y = size.height - 56

        drawText(title, x: x, y: y, width: width, size: 24, bold: true, color: ink, in: context)
        y -= 26
        drawText("Wilcom embroidery design", x: x, y: y, width: width, size: 14, bold: false, color: muted, in: context)
        y -= 34

        for row in design.infoRows {
            drawText(row.label, x: x, y: y, width: 110, size: 14, bold: false, color: muted, in: context)
            drawText(row.value, x: x + 118, y: y, width: width - 118, size: 14, bold: false, color: ink, in: context)
            y -= 24
        }

        // Swatches, as many as fit above the footnote.
        if !design.threads.isEmpty {
            y -= 14
            drawText("Threads", x: x, y: y, width: width, size: 14, bold: true, color: ink, in: context)
            y -= 28
            let floor: CGFloat = 52
            let rowHeight: CGFloat = 26
            let capacity = Swift.max(0, Int((y - floor) / rowHeight) + 1)
            let shown = design.threads.count > capacity ? Swift.max(0, capacity - 1) : design.threads.count
            for thread in design.threads.prefix(shown) {
                let swatch = CGRect(x: x, y: y - 4, width: 20, height: 20)
                context.setFillColor(CGColor(
                    srgbRed: CGFloat(thread.red) / 255, green: CGFloat(thread.green) / 255,
                    blue: CGFloat(thread.blue) / 255, alpha: 1
                ))
                context.fillEllipse(in: swatch)
                context.setStrokeColor(border)
                context.setLineWidth(1)
                context.strokeEllipse(in: swatch.insetBy(dx: 0.5, dy: 0.5))
                drawText("\(thread.stop + 1)", x: x + 30, y: y, width: 26, size: 13, bold: false, color: muted, in: context)
                drawText(thread.name.isEmpty ? thread.hexString : thread.name,
                         x: x + 60, y: y, width: width - 60, size: 14, bold: false, color: ink, in: context)
                y -= rowHeight
            }
            if shown < design.threads.count {
                drawText("+ \(design.threads.count - shown) more", x: x + 60, y: y, width: width - 60,
                         size: 13, bold: false, color: muted, in: context)
            }
        }

        drawText("Picture and facts come from the file's preview data.", x: x, y: 24, width: width,
                 size: 11, bold: false, color: muted, in: context)
    }

    // MARK: Text

    static func drawText(
        _ text: String, x: CGFloat, y: CGFloat, width: CGFloat, size: CGFloat, bold: Bool,
        color: CGColor, in context: CGContext
    ) {
        guard width > 4, !text.isEmpty else { return }
        let font = CTFontCreateWithName((bold ? "HelveticaNeue-Bold" : "HelveticaNeue") as CFString, size, nil)
        let attributes: [CFString: Any] = [kCTFontAttributeName: font, kCTForegroundColorAttributeName: color]
        guard let attributed = CFAttributedStringCreate(nil, text as CFString, attributes as CFDictionary) else { return }
        var line = CTLineCreateWithAttributedString(attributed)
        if CTLineGetTypographicBounds(line, nil, nil, nil) > Double(width),
           let token = CFAttributedStringCreate(nil, "…" as CFString, attributes as CFDictionary),
           let cut = CTLineCreateTruncatedLine(line, Double(width), .end, CTLineCreateWithAttributedString(token)) {
            line = cut
        }
        context.textPosition = CGPoint(x: x, y: y)
        CTLineDraw(line, context)
    }
}
