import CoreGraphics
import Foundation
import ImageIO
import Testing
@testable import StitchKit

// MARK: - The acceptance test

@Suite("Python reference cross-check")
struct ReferenceCrossCheckTests {

    /// The parser's real acceptance test: the Swift decode must equal the validated Python
    /// reference decode over the whole corpus, byte for byte.
    @Test("Swift decode matches the reference decoder", arguments: Fixtures.all)
    func matchesReference(_ name: String) throws {
        let golden = try #require(try Fixtures.goldens[name], "no golden for \(name)")
        let records = DSTParser.decodeRecords(data: try Fixtures.data(name))

        #expect(records.count == golden.recordCount, "record count differs for \(name)")
        #expect(records.sha256 == golden.sha256, "canonical decode differs for \(name)")

        // Where the golden carries the full list, diff it so a failure names the record.
        if let expected = golden.records {
            #expect(records.count == expected.count)
            for (index, row) in expected.enumerated() where index < records.count {
                let actual = records[index]
                #expect(
                    actual.x == row[0] && actual.y == row[1] && Int(actual.command) == row[2],
                    "record \(index) of \(name): got (\(actual.x),\(actual.y),\(actual.command)) want (\(row[0]),\(row[1]),\(row[2]))"
                )
            }
        }
    }
}

// MARK: - Orientation

@Suite("Orientation")
struct OrientationTests {

    /// The Y trap. `asymmetric.dst` is an L with a hook — mirrored in either axis it decodes
    /// to different extents, so this cannot pass by luck the way a symmetric logo would.
    @Test("Decoded extents match the header on the asymmetric fixture")
    func asymmetricMatchesHeader() throws {
        let design = try DSTParser.parse(contentsOf: Fixtures.url("asymmetric.dst"))
        let header = try #require(design.header)

        let plusX = try #require(header.plusX)
        let minusX = try #require(header.minusX)
        let plusY = try #require(header.plusY)
        let minusY = try #require(header.minusY)

        // Header extents are unsigned magnitudes in 0.1 mm; `-X`/`-Y` are absolute values.
        #expect(abs(Int(design.bounds.maxX) - plusX) <= 1)
        #expect(abs(Int(design.bounds.minX) + minusX) <= 1)
        #expect(abs(Int(design.bounds.maxY) - plusY) <= 1)
        #expect(abs(Int(design.bounds.minY) + minusY) <= 1)
    }

    /// Guards the sign directly: flipping it would put the hook on the wrong end.
    @Test("The long arm is in +X and the tall arm in +Y")
    func asymmetricShape() throws {
        let design = try DSTParser.parse(contentsOf: Fixtures.url("asymmetric.dst"))
        // Generated as: up to y=400, right to x=800, back up to y=200, left to x=600.
        #expect(design.bounds.minX == 0)
        #expect(design.bounds.maxX == 800)
        #expect(design.bounds.minY == 0)
        #expect(design.bounds.maxY == 400)
        #expect(design.bounds.width > design.bounds.height, "the long arm must be the X one")
    }

    /// Negating `dy` is what makes the above hold. This pins the reason, so a future
    /// "simplification" to `y += dy` fails loudly here.
    @Test("Reversing the Y negation breaks agreement with the header")
    func negationIsLoadBearing() throws {
        let data = try Fixtures.data("asymmetric.dst")
        let records = DSTParser.decodeRecords(data: data)
        let unnegated = records.map { -$0.y }        // what `y += dy` would have produced
        let header = try #require(DSTHeader.parse(data))

        #expect(records.map(\.y).max() == header.plusY)
        #expect(unnegated.max() != header.plusY, "an inverted Y must not agree with the header")
    }

    /// Core Graphics is y-up and the model is y-down, so the fitting transform must invert y:
    /// the smallest model y has to land at the *top* of the context.
    @Test("The fitting transform flips Y")
    func fittingTransformFlipsY() {
        let bounds = CGRect(x: 0, y: 0, width: 100, height: 200)
        let size = CGSize(width: 300, height: 600)
        let transform = DesignRenderer.fittingTransform(for: bounds, in: size, padding: 0)

        let topOfDesign = CGPoint(x: 50, y: 0).applying(transform)
        let bottomOfDesign = CGPoint(x: 50, y: 200).applying(transform)

        #expect(topOfDesign.y > bottomOfDesign.y, "model min-y must map to a larger CG y (the top)")
        #expect(abs(topOfDesign.y - size.height) < 0.001)
        #expect(abs(bottomOfDesign.y) < 0.001)
        #expect(abs(topOfDesign.x - size.width / 2) < 0.001)
    }
}

// MARK: - Header

@Suite("Header")
struct HeaderTests {

    /// The verbatim header from a real file.
    @Test("Parses a well-formed header")
    func parsesRealHeader() throws {
        var text = "LA:Untitled        \rST:    806\rCO:  1\r+X:  396\r-X:  400\r+Y:  360\r-Y:  118\r"
        text += "AX:+  396\rAY:-  285\rMX:+    0\rMY:+    0\rPD:******\r\u{1a}"
        var data = Data(text.utf8)
        data.append(contentsOf: Array(repeating: UInt8(0x20), count: 512 - data.count))

        let header = try #require(DSTHeader.parse(data))
        #expect(header.label == "Untitled")
        #expect(header.recordCount == 806)
        #expect(header.colorChanges == 1)
        #expect(header.plusX == 396)
        #expect(header.minusX == 400)      // magnitude of the negative extent, not cm
        #expect(header.plusY == 360)
        #expect(header.minusY == 118)
        #expect(header.ax == 396)
        #expect(header.ay == -285)
        #expect(header.mx == 0)
        #expect(header.previousDesign == "******")
    }

    @Test("Returns nil for a header carrying none of the known tags")
    func rejectsGarbage() throws {
        let data = try Fixtures.data("garbage-header.dst")
        #expect(DSTHeader.parse(data) == nil)
    }

    @Test("Parses TC thread colors")
    func parsesThreadColors() throws {
        var text = "LA:tc test         \rST:     10\rCO:  1\r"
        text += "TC:#1B4D9C,Royal Blue,1842\rTC:CC3311,Poppy,2201\r\u{1a}"
        var data = Data(text.utf8)
        data.append(contentsOf: Array(repeating: UInt8(0x20), count: 512 - data.count))

        let header = try #require(DSTHeader.parse(data))
        #expect(header.threadColors.count == 2)
        #expect(header.threadColors.first?.hexString == "#1B4D9C")
        #expect(header.threadColors.first?.name == "Royal Blue")
        #expect(header.threadColors.first?.catalogNumber == "1842")
        #expect(header.threadColors.last?.hexString == "#CC3311")
    }

    /// `ST` counts records, not stitches, so the parser's stitch count legitimately differs.
    @Test("ST is a record count, not a stitch count")
    func recordCountIsNotStitchCount() throws {
        let design = try DSTParser.parse(contentsOf: Fixtures.url("jumps.dst"))
        let header = try #require(design.header)
        let records = try #require(header.recordCount)
        #expect(design.stitchCount < records, "jumps and color changes inflate ST")
    }
}

// MARK: - Structure

@Suite("Blocks and runs")
struct StructureTests {

    @Test("Color changes split blocks and no phantom block trails the terminator")
    func multicolorBlocks() throws {
        let design = try DSTParser.parse(contentsOf: Fixtures.url("multicolor.dst"))
        #expect(design.colorChangeCount == 5)
        #expect(design.blocks.count == 6, "blocks are color changes + 1")
        #expect(design.blocks.allSatisfy { $0.stitchCount > 0 }, "no empty blocks")

        // Each block is a bar 100 units above the previous one.
        for (index, block) in design.blocks.enumerated() {
            #expect(abs(block.bounds.minY - CGFloat(index * 100)) <= 1)
        }
    }

    /// `0xF3` has to be tested before masking: `0xF3 & 0xC3 == 0xC3`, so masking first
    /// reads the terminator as a color change and emits a spurious empty final block.
    @Test("The 0xF3 terminator is not mistaken for a color change")
    func terminatorIsNotAColorChange() throws {
        var data = Data(count: 512)
        // One stitch, then a terminator whose masked value looks like a color change.
        data.append(contentsOf: [0x01, 0x00, 0x03])
        data.append(contentsOf: [0x00, 0x00, 0xF3])

        let design = try DSTParser.parse(data: data)
        #expect(design.blocks.count == 1)
        #expect(design.colorChangeCount == 0)
        #expect(design.isTruncated == false)
    }

    @Test("Jumps break runs")
    func jumpsBreakRuns() throws {
        let design = try DSTParser.parse(contentsOf: Fixtures.url("jumps.dst"))
        #expect(design.jumpCount > 0)
        let totalRuns = design.blocks.reduce(0) { $0 + $1.runs.count }
        #expect(totalRuns >= 4, "four separated islands cannot be one continuous run")
        // No run may contain the gap between islands.
        for block in design.blocks {
            for run in block.runs {
                for (a, b) in zip(run, run.dropFirst()) {
                    #expect(hypot(b.x - a.x, b.y - a.y) < 200, "a run jumped an island gap")
                }
            }
        }
    }

    @Test("Runs of three or more jumps are counted as trims")
    func trimsAreEstimated() throws {
        var data = Data(count: 512)
        func record(_ command: UInt8) -> [UInt8] { [0x01, 0x00, command | 0x03] }
        data.append(contentsOf: record(0x00))                     // stitch
        data.append(contentsOf: record(0x80))                     // jump
        data.append(contentsOf: record(0x80))                     // jump   (streak of 2: no trim)
        data.append(contentsOf: record(0x00))                     // stitch
        data.append(contentsOf: record(0x80))
        data.append(contentsOf: record(0x80))
        data.append(contentsOf: record(0x80))                     // streak of 3: one trim
        data.append(contentsOf: record(0x00))
        data.append(contentsOf: [0x00, 0x00, 0xF3])

        let design = try DSTParser.parse(data: data)
        #expect(design.jumpCount == 5)
        #expect(design.trimCount == 1)
    }

    @Test("Every block gets a deterministic palette color")
    func paletteIsDeterministic() throws {
        let first = try DSTParser.parse(contentsOf: Fixtures.url("multicolor.dst"))
        let second = try DSTParser.parse(contentsOf: Fixtures.url("multicolor.dst"))
        #expect(first.blocks.map(\.color) == second.blocks.map(\.color))
        #expect(first.blocks[0].color == Palette.color(at: 0))
        #expect(Palette.color(at: 16) == Palette.color(at: 0), "the palette cycles")
    }
}

// MARK: - Malformed input

@Suite("Malformed input is graceful")
struct MalformedInputTests {

    /// A crashing appex gets throttled and then silently disabled by the system, so every
    /// one of these has to produce a value or a typed error.
    @Test("A truncated file parses without its terminator")
    func truncated() throws {
        let design = try DSTParser.parse(contentsOf: Fixtures.url("truncated.dst"))
        #expect(design.isTruncated, "the terminator went with the chopped bytes")
        #expect(design.stitchCount > 0)
        #expect(design.blocks.isEmpty == false)
    }

    @Test("A garbage header does not stop the body from decoding")
    func garbageHeader() throws {
        let garbage = try DSTParser.parse(contentsOf: Fixtures.url("garbage-header.dst"))
        let clean = try DSTParser.parse(contentsOf: Fixtures.url("asymmetric.dst"))
        #expect(garbage.header == nil)
        #expect(garbage.bounds == clean.bounds, "same body, so the same geometry")
        #expect(garbage.stitchCount == clean.stitchCount)
        #expect(garbage.name == nil)
    }

    @Test("An empty design throws rather than returning something undrawable")
    func empty() throws {
        #expect(throws: DSTParseError.self) {
            _ = try DSTParser.parse(contentsOf: Fixtures.url("empty.dst"))
        }
    }

    @Test("A body length that is not a multiple of three drops the partial record")
    func partialTrailingRecord() throws {
        var data = Data(count: 512)
        data.append(contentsOf: [0x01, 0x00, 0x03])
        data.append(contentsOf: [0x01, 0x00])          // one byte short
        let design = try DSTParser.parse(data: data)
        #expect(design.stitchCount == 1)
    }

    @Test("A file shorter than the header does not trap")
    func shorterThanHeader() {
        #expect(throws: DSTParseError.self) {
            _ = try DSTParser.parse(data: Data(repeating: 0x20, count: 100))
        }
    }

    @Test("Absurd input is refused rather than allocated for")
    func absurdInput() {
        var options = DSTParser.Options()
        options.maxRecords = 10
        #expect(throws: DSTParseError.self) {
            _ = try DSTParser.parse(data: Data(count: 512 + 3 * 100), options: options)
        }
    }

    @Test("Records with the low b2 bits clear are counted and skipped")
    func invalidRecords() throws {
        var data = Data(count: 512)
        data.append(contentsOf: [0x01, 0x00, 0x03])    // valid stitch
        data.append(contentsOf: [0xFF, 0xFF, 0x00])    // low bits clear: not a valid record
        data.append(contentsOf: [0x01, 0x00, 0x03])
        data.append(contentsOf: [0x00, 0x00, 0xF3])

        let design = try DSTParser.parse(data: data)
        #expect(design.invalidRecordCount == 1)
        #expect(design.stitchCount == 2)
        #expect(design.bounds.maxX == 2, "the invalid record must not move the needle")
    }
}

// MARK: - Decimation and performance

@Suite("Decimation and performance")
struct PerformanceTests {

    @Test("Decimation drops geometry but leaves the statistics exact")
    func decimationKeepsCounts() throws {
        let full = try DSTParser.parse(contentsOf: Fixtures.url("huge.dst"))
        let thumb = try DSTParser.parse(contentsOf: Fixtures.url("huge.dst"), decimated: true)

        #expect(thumb.stitchCount == full.stitchCount, "reported counts stay exact")
        #expect(thumb.renderedPointCount < full.renderedPointCount, "geometry actually shrank")
        #expect(abs(thumb.bounds.width - full.bounds.width) <= 4)
        #expect(abs(thumb.bounds.height - full.bounds.height) <= 4)
    }

    @Test("Small designs are left alone by the decimation threshold")
    func belowThresholdIsUntouched() throws {
        let plain = try DSTParser.parse(contentsOf: Fixtures.url("asymmetric.dst"))
        let asked = try DSTParser.parse(contentsOf: Fixtures.url("asymmetric.dst"), decimated: true)
        #expect(plain.renderedPointCount == asked.renderedPointCount)
    }

    /// Quick Look kills slow extensions. Budget: under one second for 200k stitches.
    @Test("A 200k-stitch design parses and renders inside the budget")
    func performanceBudget() throws {
        let url = try Fixtures.url("huge.dst")

        let start = ContinuousClock.now
        let design = try DSTParser.parse(contentsOf: url)
        let image = DesignRenderer.image(design, size: CGSize(width: 900, height: 900))
        let elapsed = ContinuousClock.now - start

        #expect(design.stitchCount >= 200_000)
        #expect(image != nil)
        #expect(elapsed < .seconds(1), "parse + render took \(elapsed)")

        let thumbStart = ContinuousClock.now
        let thumb = try DSTParser.parse(contentsOf: url, decimated: true)
        _ = DesignRenderer.image(thumb, size: CGSize(width: 64, height: 64))
        let thumbElapsed = ContinuousClock.now - thumbStart
        #expect(thumbElapsed < .seconds(1), "thumbnail path took \(thumbElapsed)")
    }
}

// MARK: - Rendering

@Suite("Rendering")
struct RenderingTests {

    @Test("Renders every fixture that has stitches, at preview and thumbnail sizes")
    func rendersFixtures() throws {
        for name in Fixtures.all where name != "empty.dst" {
            let design = try DSTParser.parse(contentsOf: Fixtures.url(name))
            let preview = DesignRenderer.image(design, size: design.fittedSize(max: CGSize(width: 900, height: 900)))
            let thumbnail = DesignRenderer.image(design, size: CGSize(width: 64, height: 64))
            #expect(preview != nil, "no preview image for \(name)")
            #expect(thumbnail != nil, "no thumbnail image for \(name)")
        }
    }

    @Test("The background is opaque so pale thread survives on any Quick Look backdrop")
    func backgroundIsOpaque() throws {
        let design = try DSTParser.parse(contentsOf: Fixtures.url("asymmetric.dst"))
        let image = try #require(DesignRenderer.image(design, size: CGSize(width: 40, height: 40)))
        // Inside the 1 pt border, in the padding the design never reaches.
        let fabric = try #require(pixel(of: image, x: 4, y: 4))
        #expect(fabric.alpha == 255, "a transparent ground would hide white thread")
        #expect(fabric.red == 245 && fabric.green == 242 && fabric.blue == 237, "expected the #F5F2ED fabric tone")

        let corner = try #require(pixel(of: image, x: 0, y: 0))
        #expect(corner.alpha == 255)
        #expect(corner.red < fabric.red, "the 1 pt border should be darker than the fabric")
    }

    @Test("fittedSize preserves aspect ratio")
    func fittedSizeKeepsAspect() throws {
        let design = try DSTParser.parse(contentsOf: Fixtures.url("asymmetric.dst"))
        let size = design.fittedSize(max: CGSize(width: 900, height: 900))
        let designAspect = design.bounds.width / design.bounds.height
        #expect(abs(size.width / size.height - designAspect) < 0.02)
        #expect(size.width <= 900 && size.height <= 900)
    }

    @Test("The stitch scrubber limit reduces what is drawn")
    func scrubberLimit() throws {
        let design = try DSTParser.parse(contentsOf: Fixtures.url("asymmetric.dst"))
        var options = DesignRenderer.Options()
        options.maxStitch = 5
        let partial = DesignRenderer.image(design, size: CGSize(width: 200, height: 200), options: options)
        let full = DesignRenderer.image(design, size: CGSize(width: 200, height: 200))
        #expect(partial != nil && full != nil)
        #expect(inkedPixels(partial) < inkedPixels(full), "five stitches must cover less than the whole design")
    }

    /// Writes the corpus out as PNGs so the rendering can actually be looked at.
    /// Set `STITCHKIT_RENDER_DUMP` to a directory to collect them.
    @Test("Optionally dumps PNGs for visual inspection")
    func dumpRenders() throws {
        guard let directory = ProcessInfo.processInfo.environment["STITCHKIT_RENDER_DUMP"] else { return }
        let base = URL(fileURLWithPath: directory)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)

        for name in Fixtures.all where name != "empty.dst" {
            let design = try DSTParser.parse(contentsOf: Fixtures.url(name))
            let size = design.fittedSize(max: CGSize(width: 800, height: 800))
            guard let image = DesignRenderer.image(design, size: size, scale: 2) else { continue }
            let out = base.appendingPathComponent(name.replacingOccurrences(of: ".dst", with: ".png"))
            try writePNG(image, to: out)
        }
    }
}

// MARK: - Pixel helpers

struct Pixel {
    var red: Int, green: Int, blue: Int, alpha: Int
}

/// Reads one pixel. `y` counts down from the top, as CGImage rows do.
func pixel(of image: CGImage, x: Int, y: Int) -> Pixel? {
    guard let data = image.dataProvider?.data,
          let pointer = CFDataGetBytePtr(data)
    else { return nil }
    let offset = y * image.bytesPerRow + x * 4
    guard offset + 3 < CFDataGetLength(data) else { return nil }
    return Pixel(
        red: Int(pointer[offset]),
        green: Int(pointer[offset + 1]),
        blue: Int(pointer[offset + 2]),
        alpha: Int(pointer[offset + 3])
    )
}

/// Counts pixels that differ noticeably from the fabric ground.
func inkedPixels(_ image: CGImage?) -> Int {
    guard let image,
          let data = image.dataProvider?.data,
          let pointer = CFDataGetBytePtr(data)
    else { return 0 }
    let length = CFDataGetLength(data)
    var count = 0
    var index = 0
    while index + 3 < length {
        if Int(pointer[index]) < 200 || Int(pointer[index + 1]) < 200 {
            count += 1
        }
        index += 4
    }
    return count
}

func writePNG(_ image: CGImage, to url: URL) throws {
    guard let destination = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil) else {
        throw FixtureError.missingBundle
    }
    CGImageDestinationAddImage(destination, image, nil)
    CGImageDestinationFinalize(destination)
}
