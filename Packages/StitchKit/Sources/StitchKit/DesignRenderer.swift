import CoreGraphics
import Foundation

/// Draws a `Design` into any `CGContext` — preview, thumbnail, viewer, PDF or PNG export.
public enum DesignRenderer {

    /// Neutral fabric tone. Previews are composited on both light and dark backgrounds, and
    /// white or pale thread on a transparent background simply vanishes. A fixed fabric tone
    /// in both appearances reads as "a patch" and keeps light thread legible.
    /// This is deliberate — it is not a bug to be fixed by following the system appearance.
    public static let fabricComponents: (red: CGFloat, green: CGFloat, blue: CGFloat) = (0.961, 0.949, 0.929) // #F5F2ED
    public static let borderComponents: (red: CGFloat, green: CGFloat, blue: CGFloat) = (0.804, 0.784, 0.749)

    public static var fabricColor: CGColor {
        CGColor(srgbRed: fabricComponents.red, green: fabricComponents.green, blue: fabricComponents.blue, alpha: 1)
    }

    public struct Options: Sendable {
        /// Fraction of the smaller dimension left empty around the design.
        public var padding: CGFloat = 0.04
        /// Paint the fabric ground and border. Off when compositing onto an existing background.
        public var drawsBackground: Bool = true
        public var drawsBorder: Bool = true
        /// Draw needle-up moves as a faint dashed overlay. Off for previews and thumbnails.
        public var showsJumps: Bool = false
        /// Draw only the first *n* stitches, for the scrubber. `nil` draws everything.
        /// Exact only on a design that has not been decimated.
        public var maxStitch: Int?
        /// Index of the only block drawn at full strength; the rest drop to `dimmedAlpha`.
        public var isolatedBlockIndex: Int?
        public var dimmedAlpha: CGFloat = 0.12
        /// Overrides the automatic width. In output points.
        public var lineWidth: CGFloat?
        /// Replaces the automatic fit. The viewer supplies its own pan/zoom transform so
        /// stroke widths stay in real points instead of scaling with the zoom.
        /// Must still map y-down design space onto the y-up context.
        public var transform: CGAffineTransform?

        public init() {}
    }

    /// Fits `design.bounds` into `size` and strokes it.
    ///
    /// The context is assumed to be y-up, which is the Core Graphics default. The model is
    /// y-down (see `DSTParser`), so the fitting transform negates y. That flip is correct —
    /// removing it renders every design upside down, which is easy to miss on a symmetric mark.
    public static func render(
        _ design: Design,
        into context: CGContext,
        size: CGSize,
        background: CGColor? = nil,
        options: Options = Options()
    ) {
        guard size.width > 0, size.height > 0 else { return }

        context.saveGState()
        defer { context.restoreGState() }

        if options.drawsBackground {
            context.setFillColor(background ?? fabricColor)
            context.fill(CGRect(origin: .zero, size: size))
        }

        let transform = options.transform
            ?? fittingTransform(for: design.bounds, in: size, padding: options.padding)
        let scale = transform.a                     // uniform; d is -scale
        let lineWidth = options.lineWidth ?? max(0.6, 0.4 * scale)

        context.setLineCap(.round)
        context.setLineJoin(.round)
        context.setLineWidth(lineWidth)

        var remaining = options.maxStitch ?? Int.max

        for (index, block) in design.blocks.enumerated() {
            if remaining <= 0 { break }

            if options.showsJumps, !block.jumps.isEmpty {
                drawJumps(block, transform: transform, into: context, lineWidth: lineWidth)
            }

            let path = CGMutablePath()
            var used = 0
            for run in block.runs {
                if remaining - used <= 0 { break }
                let allowance = remaining - used
                let points = run.count <= allowance ? run : Array(run.prefix(allowance))
                used += points.count
                guard !points.isEmpty else { continue }
                if points.count == 1 {
                    // A lone stitch: a zero-length segment with a round cap renders as a dot.
                    let p = points[0].applying(transform)
                    path.move(to: p)
                    path.addLine(to: p)
                } else {
                    path.addLines(between: points, transform: transform)
                }
            }
            remaining -= used

            guard !path.isEmpty else { continue }

            let alpha: CGFloat = {
                guard let isolated = options.isolatedBlockIndex else { return 1 }
                return index == isolated ? 1 : options.dimmedAlpha
            }()

            context.setStrokeColor(cgColor(block.color, alpha: alpha))
            context.addPath(path)
            context.strokePath()
        }

        if options.drawsBorder {
            context.setLineWidth(1)
            context.setStrokeColor(
                CGColor(srgbRed: borderComponents.red, green: borderComponents.green, blue: borderComponents.blue, alpha: 1)
            )
            context.stroke(CGRect(origin: .zero, size: size).insetBy(dx: 0.5, dy: 0.5))
        }
    }

    private static func drawJumps(
        _ block: ColorBlock,
        transform: CGAffineTransform,
        into context: CGContext,
        lineWidth: CGFloat
    ) {
        context.saveGState()
        let path = CGMutablePath()
        for jump in block.jumps {
            path.move(to: jump.from.applying(transform))
            path.addLine(to: jump.to.applying(transform))
        }
        context.setLineWidth(0.5)
        context.setLineDash(phase: 0, lengths: [2, 2])
        context.setStrokeColor(cgColor(block.color, alpha: 0.3))
        context.addPath(path)
        context.strokePath()
        context.restoreGState()
        context.setLineWidth(lineWidth)
    }

    /// Maps design space (0.1 mm units, y-down) onto a y-up context of `size`,
    /// preserving aspect ratio and centering.
    public static func fittingTransform(for bounds: CGRect, in size: CGSize, padding: CGFloat = 0.04) -> CGAffineTransform {
        let inset = min(size.width, size.height) * padding
        let available = CGSize(
            width: max(1, size.width - 2 * inset),
            height: max(1, size.height - 2 * inset)
        )
        let width = bounds.width > 0 ? bounds.width : 1
        let height = bounds.height > 0 ? bounds.height : 1
        let scale = min(available.width / width, available.height / height)

        let offsetX = (size.width - width * scale) / 2
        let offsetY = (size.height - height * scale) / 2

        // x -> offsetX + (x - minX) * scale
        // y -> size.height - offsetY - (y - minY) * scale     (the y flip)
        return CGAffineTransform(
            a: scale, b: 0,
            c: 0, d: -scale,
            tx: offsetX - bounds.minX * scale,
            ty: size.height - offsetY + bounds.minY * scale
        )
    }

    public static func cgColor(_ color: StitchColor, alpha: CGFloat = 1) -> CGColor {
        CGColor(srgbRed: color.red, green: color.green, blue: color.blue, alpha: alpha)
    }

    // MARK: - Offscreen helpers

    /// Renders to a bitmap. Used by the exporter and by the tests that eyeball output.
    public static func image(
        _ design: Design,
        size: CGSize,
        scale: CGFloat = 1,
        background: CGColor? = nil,
        options: Options = Options()
    ) -> CGImage? {
        let pixelWidth = Int((size.width * scale).rounded())
        let pixelHeight = Int((size.height * scale).rounded())
        guard pixelWidth > 0, pixelHeight > 0,
              let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(
                data: nil,
                width: pixelWidth,
                height: pixelHeight,
                bitsPerComponent: 8,
                bytesPerRow: 0,
                space: space,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              )
        else { return nil }

        context.scaleBy(x: scale, y: scale)
        render(design, into: context, size: size, background: background, options: options)
        return context.makeImage()
    }
}
