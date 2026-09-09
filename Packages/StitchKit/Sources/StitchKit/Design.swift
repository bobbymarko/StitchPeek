import CoreGraphics
import Foundation

// MARK: - Color

/// A thread color.
///
/// Deliberately *not* `NSColor`: the model has to cross an `async` boundary inside the
/// Quick Look preview extension, and `NSColor` is not `Sendable` under Swift 6 strict
/// concurrency. `nsColor` converts at draw time.
public struct StitchColor: Sendable, Hashable {
    public var red: Double
    public var green: Double
    public var blue: Double
    /// Description from a `TC:` header entry, when the file carried one.
    public var name: String?
    /// Catalog number from a `TC:` header entry, when the file carried one.
    public var catalogNumber: String?

    public init(red: Double, green: Double, blue: Double, name: String? = nil, catalogNumber: String? = nil) {
        self.red = red
        self.green = green
        self.blue = blue
        self.name = name
        self.catalogNumber = catalogNumber
    }

    /// Parses `RRGGBB` or `#RRGGBB`. Returns `nil` for anything else.
    public init?(hex: String, name: String? = nil, catalogNumber: String? = nil) {
        var s = hex.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("#") { s.removeFirst() }
        guard s.count == 6, let v = UInt32(s, radix: 16) else { return nil }
        self.init(
            red: Double((v >> 16) & 0xFF) / 255.0,
            green: Double((v >> 8) & 0xFF) / 255.0,
            blue: Double(v & 0xFF) / 255.0,
            name: name,
            catalogNumber: catalogNumber
        )
    }

    public var hexString: String {
        func c(_ v: Double) -> Int { Int((v * 255).rounded().clamped(to: 0...255)) }
        return String(format: "#%02X%02X%02X", c(red), c(green), c(blue))
    }
}

// MARK: - Geometry

/// A needle-up move. Kept for the optional jump overlay in the viewer; never drawn in
/// previews or thumbnails.
public struct JumpSegment: Sendable, Hashable {
    public var from: CGPoint
    public var to: CGPoint

    public init(from: CGPoint, to: CGPoint) {
        self.from = from
        self.to = to
    }
}

// MARK: - Color block

/// Everything stitched between two color changes.
public struct ColorBlock: Sendable {
    /// Each run is one contiguous length of stitching. Jumps break runs, so a
    /// straight polyline through a run is always real thread.
    public var runs: [[CGPoint]]
    public var jumps: [JumpSegment]
    public var color: StitchColor
    public var stitchCount: Int
    public var jumpCount: Int
    /// Bounds of this block's stitches alone, in 0.1 mm units.
    public var bounds: CGRect

    public init(
        runs: [[CGPoint]],
        jumps: [JumpSegment],
        color: StitchColor,
        stitchCount: Int,
        jumpCount: Int,
        bounds: CGRect
    ) {
        self.runs = runs
        self.jumps = jumps
        self.color = color
        self.stitchCount = stitchCount
        self.jumpCount = jumpCount
        self.bounds = bounds
    }
}

// MARK: - Design

/// A format-agnostic stitch design.
///
/// **Units.** Coordinates stay in 0.1 mm throughout. Convert to mm (`/10`) or
/// inches (`/254`) only at display time.
///
/// **Orientation.** +Y is *down*, matching what DST stores and what pyembroidery
/// reports. Core Graphics is y-up, so `DesignRenderer` applies a vertical flip.
/// See the note in `DSTParser`.
public struct Design: Sendable {
    public var blocks: [ColorBlock]
    public var header: DSTHeader?
    /// Bounds over stitch points, in 0.1 mm units.
    public var bounds: CGRect
    public var stitchCount: Int
    public var jumpCount: Int
    /// Estimated: DST has no trim command, so runs of 3+ consecutive jumps are counted as one trim.
    public var trimCount: Int
    /// Number of color-change records seen. Block count is usually this + 1.
    public var colorChangeCount: Int
    /// True when the record stream ran out without a `0xF3` terminator.
    public var isTruncated: Bool
    /// Records whose `b2` low two bits were not both set — a sign of corruption.
    public var invalidRecordCount: Int

    public init(
        blocks: [ColorBlock],
        header: DSTHeader?,
        bounds: CGRect,
        stitchCount: Int,
        jumpCount: Int,
        trimCount: Int,
        colorChangeCount: Int,
        isTruncated: Bool,
        invalidRecordCount: Int
    ) {
        self.blocks = blocks
        self.header = header
        self.bounds = bounds
        self.stitchCount = stitchCount
        self.jumpCount = jumpCount
        self.trimCount = trimCount
        self.colorChangeCount = colorChangeCount
        self.isTruncated = isTruncated
        self.invalidRecordCount = invalidRecordCount
    }

    /// Design name from the header, trimmed. `nil` when absent or blank.
    public var name: String? {
        guard let raw = header?.label?.trimmingCharacters(in: .whitespaces), !raw.isEmpty else { return nil }
        return raw
    }

    public var widthMM: Double { Double(bounds.width) / 10.0 }
    public var heightMM: Double { Double(bounds.height) / 10.0 }
    public var widthInches: Double { Double(bounds.width) / 254.0 }
    public var heightInches: Double { Double(bounds.height) / 254.0 }

    /// The largest size with the design's aspect ratio that fits inside `max`.
    /// Falls back to a square when the design has no extent.
    public func fittedSize(max maxSize: CGSize) -> CGSize {
        let w = bounds.width, h = bounds.height
        guard w > 0, h > 0, maxSize.width > 0, maxSize.height > 0 else {
            let side = Swift.min(maxSize.width, maxSize.height)
            return CGSize(width: side, height: side)
        }
        let scale = Swift.min(maxSize.width / w, maxSize.height / h)
        return CGSize(
            width: Swift.max(1, (w * scale).rounded()),
            height: Swift.max(1, (h * scale).rounded())
        )
    }
}

// MARK: - Utilities

extension Comparable {
    func clamped(to range: ClosedRange<Self>) -> Self {
        Swift.min(Swift.max(self, range.lowerBound), range.upperBound)
    }
}
