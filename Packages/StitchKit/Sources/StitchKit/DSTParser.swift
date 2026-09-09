import CoreGraphics
import Foundation

public enum DSTParseError: Error, LocalizedError, Sendable {
    /// The file could not be read off disk.
    case unreadable(String)
    /// Absurd input — refuse rather than allocate for minutes.
    case tooManyRecords(Int)
    /// Parsed cleanly but there is nothing to draw.
    case noStitches

    public var errorDescription: String? {
        switch self {
        case .unreadable(let why):
            return "The design file could not be read. \(why)"
        case .tooManyRecords(let count):
            return "The file claims \(count) stitch records, which is too large to be a real design."
        case .noStitches:
            return "The file contains no stitches."
        }
    }
}

/// Decoder for Tajima DST.
///
/// File shape: a 512-byte ASCII header, then 3-byte records until a `0xF3`
/// terminator, then optional padding.
///
/// Every path returns a value or throws a typed error — nothing traps, and there are
/// no force-unwraps. A Quick Look extension that crashes gets throttled and then
/// silently disabled by the system.
public enum DSTParser {

    public static let headerLength = 512
    public static let recordLength = 3

    public struct Options: Sendable {
        /// Refuse files above this record count instead of allocating forever.
        public var maxRecords: Int
        /// When set, and the design exceeds `decimationThreshold` stitches, drop points
        /// that land closer together than one pixel at this output size. Geometry only —
        /// the reported stitch counts stay exact.
        public var decimateToPixels: CGFloat?
        public var decimationThreshold: Int

        public init(
            maxRecords: Int = 5_000_000,
            decimateToPixels: CGFloat? = nil,
            decimationThreshold: Int = 50_000
        ) {
            self.maxRecords = maxRecords
            self.decimateToPixels = decimateToPixels
            self.decimationThreshold = decimationThreshold
        }
    }

    // MARK: - Entry points

    public static func parse(contentsOf url: URL, options: Options = Options()) throws -> Design {
        let data: Data
        do {
            data = try Data(contentsOf: url, options: .mappedIfSafe)
        } catch {
            throw DSTParseError.unreadable(error.localizedDescription)
        }
        return try parse(data: data, options: options)
    }

    /// Convenience matching the thumbnail extension's call site.
    public static func parse(contentsOf url: URL, decimated: Bool) throws -> Design {
        var options = Options()
        if decimated { options.decimateToPixels = 512 }
        return try parse(contentsOf: url, options: options)
    }

    public static func parse(data: Data, options: Options = Options()) throws -> Design {
        let bodyBytes = max(0, data.count - headerLength)
        let approximateRecords = bodyBytes / recordLength
        guard approximateRecords <= options.maxRecords else {
            throw DSTParseError.tooManyRecords(approximateRecords)
        }

        let header = DSTHeader.parse(data)
        var design = data.withUnsafeBytes { raw in
            decode(raw, header: header)
        }

        guard design.stitchCount > 0 else { throw DSTParseError.noStitches }

        if let pixels = options.decimateToPixels, design.stitchCount > options.decimationThreshold {
            let longestSide = max(design.bounds.width, design.bounds.height)
            if longestSide > 0, pixels > 0 {
                design = design.decimated(tolerance: longestSide / pixels)
            }
        }
        return design
    }

    // MARK: - Record decoding

    /// One decoded 3-byte record: the absolute position after the move, and the control code.
    public struct Record: Sendable, Equatable {
        public var x: Int
        public var y: Int
        /// `b2 & 0xC3` — `0x03` stitch, `0x83` jump, `0xC3` color change, `0x43` sequin toggle.
        public var command: UInt8

        public init(x: Int, y: Int, command: UInt8) {
            self.x = x
            self.y = y
            self.command = command
        }
    }

    /// The coordinate bit table, in one place.
    ///
    ///     byte  bit7  bit6  bit5  bit4  bit3  bit2  bit1  bit0
    ///     b0    y+1   y-1   y+9   y-9   x-9   x+9   x-1   x+1
    ///     b1    y+3   y-3   y+27  y-27  x-27  x+27  x-3   x+3
    ///     b2    c1    c0    y+81  y-81  x-81  x+81   1     1
    ///
    /// Bits are weighted by powers of three, so each record moves at most ±121 per axis.
    /// The returned `dy` is in the table's sense; callers subtract it (see `decode`).
    @inline(__always)
    static func delta(_ b0: UInt8, _ b1: UInt8, _ b2: UInt8) -> (dx: Int, dy: Int) {
        var dx = 0, dy = 0
        if b0 & 0x01 != 0 { dx += 1 }
        if b0 & 0x02 != 0 { dx -= 1 }
        if b0 & 0x04 != 0 { dx += 9 }
        if b0 & 0x08 != 0 { dx -= 9 }
        if b0 & 0x80 != 0 { dy += 1 }
        if b0 & 0x40 != 0 { dy -= 1 }
        if b0 & 0x20 != 0 { dy += 9 }
        if b0 & 0x10 != 0 { dy -= 9 }
        if b1 & 0x01 != 0 { dx += 3 }
        if b1 & 0x02 != 0 { dx -= 3 }
        if b1 & 0x04 != 0 { dx += 27 }
        if b1 & 0x08 != 0 { dx -= 27 }
        if b1 & 0x80 != 0 { dy += 3 }
        if b1 & 0x40 != 0 { dy -= 3 }
        if b1 & 0x20 != 0 { dy += 27 }
        if b1 & 0x10 != 0 { dy -= 27 }
        if b2 & 0x04 != 0 { dx += 81 }
        if b2 & 0x08 != 0 { dx -= 81 }
        if b2 & 0x20 != 0 { dy += 81 }
        if b2 & 0x10 != 0 { dy -= 81 }
        return (dx, dy)
    }

    /// Decodes the raw record stream with no grouping into blocks or runs.
    ///
    /// This is the direct analogue of the Python reference decoder and exists so the two
    /// can be diffed over a corpus — that comparison is the parser's real acceptance test.
    /// It shares `delta` with `decode`, so it cannot drift from what the app renders.
    public static func decodeRecords(data: Data) -> [Record] {
        data.withUnsafeBytes { raw in
            var records: [Record] = []
            let n = raw.count
            guard n > headerLength else { return records }
            records.reserveCapacity((n - headerLength) / recordLength)

            var x = 0, y = 0
            var index = headerLength
            while index + recordLength <= n {
                let b0 = raw[index], b1 = raw[index + 1], b2 = raw[index + 2]
                if b2 == 0xF3 { break }
                let (dx, dy) = delta(b0, b1, b2)
                x += dx
                y -= dy
                records.append(Record(x: x, y: y, command: b2 & 0xC3))
                index += recordLength
            }
            return records
        }
    }


    /// Decodes the 3-byte record stream.
    ///
    /// Coordinate bits are weighted by powers of three, giving ±121 per record per axis:
    ///
    ///     byte  bit7  bit6  bit5  bit4  bit3  bit2  bit1  bit0
    ///     b0    y+1   y-1   y+9   y-9   x-9   x+9   x-1   x+1
    ///     b1    y+3   y-3   y+27  y-27  x-27  x+27  x-3   x+3
    ///     b2    c1    c0    y+81  y-81  x-81  x+81   1     1
    ///
    /// **The Y trap.** The table yields a `dy` inverted relative to what DST stores, so it
    /// is subtracted, not added. With the negation the decoded extents match the header's
    /// `+Y`/`-Y` exactly and match pyembroidery stitch-for-stitch.
    ///
    /// The resulting model is **y-down**: larger y is further down the design. Verified by
    /// rendering real lettering, and by pyembroidery writing these coordinates straight into
    /// SVG (also y-down) with no transform. Core Graphics is y-*up*, so `DesignRenderer`
    /// flips. Do not remove that flip.
    private static func decode(_ raw: UnsafeRawBufferPointer, header: DSTHeader?) -> Design {
        let n = raw.count
        var index = headerLength

        var x = 0, y = 0
        var minX = Int.max, maxX = Int.min, minY = Int.max, maxY = Int.min

        var blocks: [ColorBlock] = []
        var runs: [[CGPoint]] = []
        var currentRun: [CGPoint] = []
        var jumps: [JumpSegment] = []

        var blockStitches = 0, blockJumps = 0
        var blockMinX = Int.max, blockMaxX = Int.min, blockMinY = Int.max, blockMaxY = Int.min

        var totalStitches = 0, totalJumps = 0, trimCount = 0, colorChanges = 0
        var invalidRecords = 0
        var jumpStreak = 0
        var sawTerminator = false

        func closeRun() {
            if !currentRun.isEmpty {
                runs.append(currentRun)
                currentRun.removeAll(keepingCapacity: true)
            }
        }

        func closeBlock() {
            closeRun()
            // Skip empty blocks so a trailing color change cannot produce a phantom block.
            guard blockStitches > 0 || !runs.isEmpty else {
                runs.removeAll(keepingCapacity: true)
                jumps.removeAll(keepingCapacity: true)
                blockStitches = 0
                blockJumps = 0
                blockMinX = Int.max; blockMaxX = Int.min; blockMinY = Int.max; blockMaxY = Int.min
                return
            }
            let bounds: CGRect
            if blockMinX <= blockMaxX {
                bounds = CGRect(
                    x: CGFloat(blockMinX),
                    y: CGFloat(blockMinY),
                    width: CGFloat(blockMaxX - blockMinX),
                    height: CGFloat(blockMaxY - blockMinY)
                )
            } else {
                bounds = .zero
            }
            blocks.append(
                ColorBlock(
                    runs: runs,
                    jumps: jumps,
                    color: Palette.color(at: blocks.count),
                    stitchCount: blockStitches,
                    jumpCount: blockJumps,
                    bounds: bounds
                )
            )
            runs.removeAll(keepingCapacity: true)
            jumps.removeAll(keepingCapacity: true)
            blockStitches = 0
            blockJumps = 0
            blockMinX = Int.max; blockMaxX = Int.min; blockMinY = Int.max; blockMaxY = Int.min
        }

        func endJumpStreak() {
            // DST has no trim command. Three or more consecutive jumps conventionally means a trim.
            if jumpStreak >= 3 { trimCount += 1 }
            jumpStreak = 0
        }

        // A body length that is not a multiple of 3 simply loses its trailing partial record.
        while index + recordLength <= n {
            let b0 = raw[index]
            let b1 = raw[index + 1]
            let b2 = raw[index + 2]

            // Checked before masking: 0xF3 & 0xC3 == 0xC3, so masking first would read the
            // terminator as a color change and emit a spurious empty final block.
            if b2 == 0xF3 {
                sawTerminator = true
                break
            }

            // Bits 0 and 1 of b2 are set in every valid record.
            guard b2 & 0x03 == 0x03 else {
                invalidRecords += 1
                index += recordLength
                continue
            }

            let (dx, dy) = delta(b0, b1, b2)

            let previous = CGPoint(x: CGFloat(x), y: CGFloat(y))
            x += dx
            y -= dy                     // see the note above — not `+=`
            let point = CGPoint(x: CGFloat(x), y: CGFloat(y))

            switch b2 & 0xC3 {
            case 0x03:                  // normal stitch: needle down, extend the run
                endJumpStreak()
                currentRun.append(point)
                blockStitches += 1
                totalStitches += 1
                if x < minX { minX = x }; if x > maxX { maxX = x }
                if y < minY { minY = y }; if y > maxY { maxY = y }
                if x < blockMinX { blockMinX = x }; if x > blockMaxX { blockMaxX = x }
                if y < blockMinY { blockMinY = y }; if y > blockMaxY { blockMaxY = y }

            case 0x83:                  // jump: needle up, breaks the run
                closeRun()
                jumps.append(JumpSegment(from: previous, to: point))
                blockJumps += 1
                totalJumps += 1
                jumpStreak += 1

            case 0xC3:                  // color change / stop
                endJumpStreak()
                colorChanges += 1
                closeBlock()

            case 0x43:                  // sequin mode toggle: move the pen, do not stitch
                endJumpStreak()
                closeRun()

            default:
                endJumpStreak()
            }

            index += recordLength
        }

        endJumpStreak()
        closeBlock()

        let bounds: CGRect
        if minX <= maxX {
            bounds = CGRect(
                x: CGFloat(minX),
                y: CGFloat(minY),
                width: CGFloat(maxX - minX),
                height: CGFloat(maxY - minY)
            )
        } else {
            bounds = .zero
        }

        return Design(
            blocks: blocks,
            header: header,
            bounds: bounds,
            stitchCount: totalStitches,
            jumpCount: totalJumps,
            trimCount: trimCount,
            colorChangeCount: colorChanges,
            isTruncated: !sawTerminator,
            invalidRecordCount: invalidRecords
        )
    }
}

// MARK: - Decimation

extension Design {
    /// Drops points that land closer than `tolerance` (in 0.1 mm units) to the previously
    /// kept point. Endpoints of every run are always kept, so outlines stay closed.
    ///
    /// Geometry only: `stitchCount` and the other statistics are left exact.
    public func decimated(tolerance: CGFloat) -> Design {
        guard tolerance > 0 else { return self }
        let squaredTolerance = tolerance * tolerance
        var copy = self
        copy.blocks = blocks.map { block in
            var reduced = block
            reduced.runs = block.runs.map { run in
                guard run.count > 2 else { return run }
                var kept: [CGPoint] = [run[0]]
                kept.reserveCapacity(run.count / 2)
                var anchor = run[0]
                for point in run.dropFirst() {
                    let dx = point.x - anchor.x
                    let dy = point.y - anchor.y
                    if dx * dx + dy * dy >= squaredTolerance {
                        kept.append(point)
                        anchor = point
                    }
                }
                if let last = run.last, kept.last != last { kept.append(last) }
                return kept
            }
            return reduced
        }
        return copy
    }

    /// Total number of points actually held for drawing. Differs from `stitchCount` after decimation.
    public var renderedPointCount: Int {
        blocks.reduce(0) { $0 + $1.runs.reduce(0) { $0 + $1.count } }
    }
}
