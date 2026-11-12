import Compression
import CoreGraphics
import Foundation
import Testing
@testable import StitchKit

// MARK: - Synthetic files
//
// Nothing here is a real design: the container and property set are built byte by byte, so the
// suite needs no committed sample. Real files (private, never committed) are checked by
// `Scripts/test_emb_reference.py`, and here only when STITCHPEEK_EMB_SAMPLES points at some.

/// Builds a version-3 compound file: one FAT sector, a directory, a mini stream, and regular
/// sectors for any stream of 4096 bytes or more. Total size is capped at one FAT sector (128).
enum SyntheticCFB {
    static let endOfChain: UInt32 = 0xFFFF_FFFE
    static let free: UInt32 = 0xFFFF_FFFF
    static let fatMarker: UInt32 = 0xFFFF_FFFD

    static func le32(_ v: UInt32) -> [UInt8] { [UInt8(v & 0xFF), UInt8((v >> 8) & 0xFF), UInt8((v >> 16) & 0xFF), UInt8(v >> 24)] }
    static func le16(_ v: Int) -> [UInt8] { [UInt8(v & 0xFF), UInt8((v >> 8) & 0xFF)] }

    static func padded(_ a: [UInt8], to unit: Int) -> [UInt8] {
        let rem = a.count % unit
        return rem == 0 ? a : a + [UInt8](repeating: 0, count: unit - rem)
    }

    static func build(_ streams: [(name: String, data: [UInt8])]) -> Data {
        let ss = 512
        // Mini stream.
        var mini: [UInt8] = []
        var miniFAT: [UInt32] = []
        var starts: [UInt32] = []
        var large: [(index: Int, data: [UInt8])] = []
        for (i, s) in streams.enumerated() {
            if s.data.count >= 4096 {
                large.append((i, s.data))
                starts.append(0)
                continue
            }
            let n = max(1, (s.data.count + 63) / 64)
            let first = UInt32(miniFAT.count)
            starts.append(s.data.isEmpty ? endOfChain : first)
            if s.data.isEmpty { continue }
            for k in 0..<n { miniFAT.append(k == n - 1 ? endOfChain : first + UInt32(k) + 1) }
            mini += padded(s.data, to: 64)
        }
        while miniFAT.count % 128 != 0 || miniFAT.isEmpty { miniFAT.append(free) }
        let miniFATSectors = miniFAT.count / 128
        let miniSectors = mini.isEmpty ? 0 : padded(mini, to: ss).count / ss

        let dirSectors = (1 + streams.count + 3) / 4
        // Sector plan: 0 = FAT, then directory, mini-FAT, mini container, large streams.
        var next: UInt32 = 1
        let dirStart = next; next += UInt32(dirSectors)
        let miniFATStart = next; next += UInt32(miniFATSectors)
        let miniStart = next; next += UInt32(miniSectors)
        var fat = [UInt32](repeating: free, count: 128)
        fat[0] = fatMarker
        func chain(_ first: UInt32, _ count: Int) {
            for k in 0..<count { fat[Int(first) + k] = k == count - 1 ? endOfChain : first + UInt32(k) + 1 }
        }
        chain(dirStart, dirSectors)
        chain(miniFATStart, miniFATSectors)
        if miniSectors > 0 { chain(miniStart, miniSectors) }
        var largeSectors: [UInt8] = []
        for item in large {
            let count = (item.data.count + ss - 1) / ss
            starts[item.index] = next
            chain(next, count)
            next += UInt32(count)
            largeSectors += padded(item.data, to: ss)
        }
        precondition(next <= 128, "synthetic file too big for one FAT sector")

        // Directory: the root, then every stream chained as right siblings.
        func entry(name: String, type: UInt8, left: UInt32, right: UInt32, child: UInt32, start: UInt32, size: Int) -> [UInt8] {
            var e = [UInt8](repeating: 0, count: 128)
            let units = Array(name.utf16)
            for (k, u) in units.enumerated() { e[2 * k] = UInt8(u & 0xFF); e[2 * k + 1] = UInt8(u >> 8) }
            e[64] = UInt8((units.count + 1) * 2)
            e[66] = type
            e[67] = 1
            e.replaceSubrange(68..<72, with: le32(left))
            e.replaceSubrange(72..<76, with: le32(right))
            e.replaceSubrange(76..<80, with: le32(child))
            e.replaceSubrange(116..<120, with: le32(start))
            e.replaceSubrange(120..<124, with: le32(UInt32(size)))
            return e
        }
        var dir = entry(
            name: "Root Entry", type: 5, left: free, right: free, child: streams.isEmpty ? free : 1,
            start: miniSectors > 0 ? miniStart : endOfChain, size: mini.count
        )
        for (i, s) in streams.enumerated() {
            dir += entry(
                name: s.name, type: 2, left: free, right: i == streams.count - 1 ? free : UInt32(i + 2),
                child: free, start: starts[i], size: s.data.count
            )
        }
        while dir.count % ss != 0 {
            dir += entry(name: "", type: 0, left: free, right: free, child: free, start: 0, size: 0)
        }

        var header = [UInt8](repeating: 0, count: 512)
        header.replaceSubrange(0..<8, with: [0xD0, 0xCF, 0x11, 0xE0, 0xA1, 0xB1, 0x1A, 0xE1])
        header.replaceSubrange(0x18..<0x1A, with: le16(0x3E))
        header.replaceSubrange(0x1A..<0x1C, with: le16(3))
        header.replaceSubrange(0x1C..<0x1E, with: le16(0xFFFE))
        header.replaceSubrange(0x1E..<0x20, with: le16(9))
        header.replaceSubrange(0x20..<0x22, with: le16(6))
        header.replaceSubrange(0x2C..<0x30, with: le32(1))
        header.replaceSubrange(0x30..<0x34, with: le32(dirStart))
        header.replaceSubrange(0x38..<0x3C, with: le32(4096))
        header.replaceSubrange(0x3C..<0x40, with: le32(miniFATStart))
        header.replaceSubrange(0x40..<0x44, with: le32(UInt32(miniFATSectors)))
        header.replaceSubrange(0x44..<0x48, with: le32(endOfChain))
        for i in 0..<109 {
            header.replaceSubrange((0x4C + 4 * i)..<(0x50 + 4 * i), with: le32(i == 0 ? 0 : free))
        }

        var file = header
        file += fat.flatMap(le32)
        file += dir
        file += miniFAT.flatMap(le32)
        file += padded(mini, to: ss)
        file += largeSectors
        return Data(file)
    }
}

/// An OLE property set shaped like Wilcom's design-info stream, including the name dictionary.
enum SyntheticDesignInfo {
    enum Value {
        case int(Int32)
        case double(Double)
        case string(String)
        case blob([UInt8])
    }

    static func build(_ fields: [(id: UInt32, name: String, value: Value)]) -> [UInt8] {
        func le32(_ v: UInt32) -> [UInt8] { SyntheticCFB.le32(v) }
        // Dictionary (property 0).
        var dict = le32(UInt32(fields.count))
        for f in fields {
            let text = Array(f.name.utf8) + [0]
            dict += le32(f.id) + le32(UInt32(text.count)) + text
        }
        var props: [(UInt32, [UInt8])] = [(0, dict)]
        for f in fields {
            var v: [UInt8]
            switch f.value {
            case .int(let x): v = le32(3) + le32(UInt32(bitPattern: x))
            case .double(let x):
                v = le32(5)
                for k in 0..<8 { v.append(UInt8((x.bitPattern >> (8 * UInt64(k))) & 0xFF)) }
            case .string(let s):
                let text = Array(s.utf8) + [0]
                v = le32(0x1E) + le32(UInt32(text.count)) + text
            case .blob(let b): v = le32(0x41) + le32(UInt32(b.count)) + b
            }
            props.append((f.id, v))
        }
        let table = 8 + 8 * props.count
        var offsets: [UInt32] = []
        var body: [UInt8] = []
        for p in props { offsets.append(UInt32(table + body.count)); body += p.1 }
        var section = le32(UInt32(table + body.count)) + le32(UInt32(props.count))
        for (i, p) in props.enumerated() { section += le32(p.0) + le32(offsets[i]) }
        section += body

        var out = SyntheticCFB.le16(0xFFFE) + SyntheticCFB.le16(0) + le32(0x0002_0006)
        out += [UInt8](repeating: 0, count: 16)                 // CLSID
        out += le32(1)                                          // one section
        out += [UInt8](repeating: 0xAB, count: 16)              // FMTID
        out += le32(48)                                         // section offset
        return out + section
    }
}

enum SyntheticEMB {
    static let width = 11479.0
    static let height = 8905.0

    static func record(stop: Int, slot: Int, code: Int, name: String, chart: String, colorRef: UInt32) -> [UInt8] {
        var r = [UInt8](repeating: 0, count: EMBReader.sequenceRecordSize)
        r.replaceSubrange(0..<4, with: SyntheticCFB.le32(UInt32(stop)))
        r.replaceSubrange(4..<8, with: SyntheticCFB.le32(UInt32(slot)))
        r.replaceSubrange(8..<12, with: SyntheticCFB.le32(UInt32(code)))
        r.replaceSubrange(20..<(20 + name.utf8.count), with: Array(name.utf8))
        r.replaceSubrange(276..<(276 + chart.utf8.count), with: Array(chart.utf8))
        r.replaceSubrange(792..<796, with: SyntheticCFB.le32(colorRef))
        return r
    }

    /// 2 x 2, 24-bit BMP: red, green / blue, white.
    static let bmp: [UInt8] = {
        var b: [UInt8] = [0x42, 0x4D]
        let pixels: [UInt8] = [
            0xFF, 0x00, 0x00, 0xFF, 0xFF, 0xFF, 0x00, 0x00,     // bottom row (BGR): blue, white, pad
            0x00, 0x00, 0xFF, 0x00, 0xFF, 0x00, 0x00, 0x00,     // top row: red, green, pad
        ]
        b += SyntheticCFB.le32(UInt32(54 + pixels.count)) + [0, 0, 0, 0] + SyntheticCFB.le32(54)
        b += SyntheticCFB.le32(40) + SyntheticCFB.le32(2) + SyntheticCFB.le32(2)
        b += SyntheticCFB.le16(1) + SyntheticCFB.le16(24) + SyntheticCFB.le32(0) + SyntheticCFB.le32(UInt32(pixels.count))
        b += SyntheticCFB.le32(2835) + SyntheticCFB.le32(2835) + SyntheticCFB.le32(0) + SyntheticCFB.le32(0)
        return b + pixels
    }()

    static let fakeJPEG: [UInt8] = [0xFF, 0xD8, 0xFF, 0xE0] + Array("not really a picture".utf8) + [0xFF, 0xD9]

    static func adler32(_ data: [UInt8]) -> UInt32 {
        var a: UInt32 = 1, b: UInt32 = 0
        for byte in data { a = (a + UInt32(byte)) % 65521; b = (b + a) % 65521 }
        return b << 16 | a
    }

    /// zlib framing around stored (uncompressed) deflate blocks.
    static func zlibStored(_ data: [UInt8]) -> [UInt8] {
        precondition(data.count < 65536)
        let n = data.count
        var out: [UInt8] = [0x78, 0x01, 0x01, UInt8(n & 0xFF), UInt8(n >> 8), UInt8(~n & 0xFF), UInt8((~n >> 8) & 0xFF)]
        out += data
        out += adler32(data).bigEndianBytes
        return out
    }

    /// zlib framing around genuinely compressed data, from Apple's own encoder.
    static func zlibCompressed(_ data: [UInt8]) -> [UInt8] {
        var scratch = [UInt8](repeating: 0, count: data.count + 1024)
        let n = data.withUnsafeBufferPointer { src in
            scratch.withUnsafeMutableBufferPointer { dst in
                compression_encode_buffer(dst.baseAddress!, dst.count, src.baseAddress!, src.count, nil, COMPRESSION_ZLIB)
            }
        }
        let body = Array(scratch[0..<n])
        return [0x78, 0x9C] + body + adler32(data).bigEndianBytes
    }

    static func previewStream(_ payload: [UInt8], compressed: Bool) -> [UInt8] {
        SyntheticCFB.le32(UInt32(payload.count)) + (compressed ? zlibCompressed(payload) : zlibStored(payload))
    }

    static func build(withPreviews: Bool = true, withDesignStream: Bool = true) -> Data {
        let sequence = record(stop: 0, slot: 15, code: 2142, name: "R0 G0 B0", chart: "", colorRef: 0x0000_0000)
            + record(stop: 1, slot: 3, code: 1801, name: "Dark Green", chart: "Default", colorRef: 0x0020_8040)
        let info = SyntheticDesignInfo.build([
            (3, "number of colours", .int(2)),
            (4, "number of stops", .int(2)),
            (5, "number of trims", .int(4)),
            (6, "number of stitches", .int(2143)),
            (7, "number of objects", .int(6)),
            (8, "thread length", .double(2_506_695.0)),
            (9, "bobbin length", .double(1_017_395.0)),
            (16, "design height", .double(height)),
            (17, "design width", .double(width)),
            (18, "sequence list", .blob(sequence)),
            (19, "embroidery machine name", .string("Tajima TBF")),
            (27, "number of colour changes", .int(1)),
            (33, "colorway", .string("Colorway 1")),
            (43, "source", .string("Native design")),
        ])
        var streams: [(name: String, data: [UInt8])] = [
            ("\u{05}SummaryInformation", [UInt8](repeating: 0, count: 64)),
            (EMBReader.designInfoStream, info),
            ("AUX_INFO", [UInt8](repeating: 1, count: 17)),
        ]
        if withPreviews {
            streams.append((EMBReader.designIconStream, previewStream(bmp, compressed: false)))
            // Large enough to land in regular sectors rather than the mini stream.
            var big = fakeJPEG
            var seed: UInt32 = 7
            while big.count < 6000 { seed = seed &* 1_664_525 &+ 1_013_904_223; big.append(UInt8(seed >> 24)) }
            streams.append((EMBReader.trueViewStream, previewStream(big, compressed: true)))
        }
        // Stands in for the encrypted design stream: present, noise, never read.
        if withDesignStream {
            streams.append(("DesignDocument", (0..<5000).map { UInt8(truncatingIfNeeded: $0 &* 2_654_435_761) }))
        }
        return SyntheticCFB.build(streams)
    }
}

private extension UInt32 {
    var bigEndianBytes: [UInt8] { [UInt8(self >> 24), UInt8((self >> 16) & 0xFF), UInt8((self >> 8) & 0xFF), UInt8(self & 0xFF)] }
}

// MARK: - Container

@Suite("CFB reader")
struct CFBReaderTests {

    @Test("Reads mini-stream and regular-sector streams back exactly")
    func roundTrip() throws {
        let small = (0..<300).map { UInt8($0 % 251) }
        let big = (0..<9000).map { UInt8(($0 * 7) % 253) }
        let empty: [UInt8] = []
        let cfb = try CFBFile(data: SyntheticCFB.build([("a", small), ("b", big), ("c", empty), ("\u{05}x", [1, 2, 3])]))
        #expect(try cfb.stream(named: "a") == small)
        #expect(try cfb.stream(named: "b") == big)
        #expect(try cfb.stream(named: "c") == empty)
        #expect(try cfb.stream(named: "\u{05}x") == [1, 2, 3])
        #expect(cfb.streamNames.sorted() == ["a", "b", "c", "\u{05}x"].sorted())
    }

    @Test("A missing stream is a thrown error")
    func missingStream() throws {
        let cfb = try CFBFile(data: SyntheticCFB.build([("a", [1])]))
        #expect(throws: CFBError.streamNotFound("nope")) { try cfb.stream(named: "nope") }
    }

    @Test("Garbage is rejected", arguments: [0, 100, 511, 512, 4096])
    func garbage(_ size: Int) {
        #expect(throws: CFBError.self) { try CFBFile(data: Data(repeating: 0xFF, count: size)) }
        #expect(throws: CFBError.self) { try CFBFile(data: Data(repeating: 0, count: size)) }
    }

    @Test("Truncation and corruption never trap")
    func damage() throws {
        let good = SyntheticEMB.build()
        for cut in stride(from: 0, to: good.count, by: 97) {
            let cfb = try? CFBFile(data: good.prefix(cut))
            for name in cfb?.streamNames ?? [] { _ = try? cfb?.stream(named: name) }
            _ = try? EMBReader.parse(data: good.prefix(cut))
        }
        // Deterministic byte flips across the header, FAT and directory, where lengths and
        // chain pointers live.
        var seed: UInt64 = 0x9E37_79B9
        for _ in 0..<400 {
            var bytes = [UInt8](good)
            for _ in 0..<4 {
                seed = seed &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
                let at = Int((seed >> 33) % 2500)
                bytes[at] = UInt8(truncatingIfNeeded: seed >> 20)
            }
            let cfb = try? CFBFile(data: Data(bytes))
            for name in cfb?.streamNames ?? [] { _ = try? cfb?.stream(named: name) }
            _ = try? EMBReader.parse(data: Data(bytes))
        }
    }

    @Test("A FAT chain that loops is an error, not a hang")
    func cycle() throws {
        // Sector plan for a file with one large stream: 0 FAT, 1 directory, 2 mini-FAT, 3... stream.
        // The FAT is sector 0, at file offset 512; entry n is 4 bytes at 512 + 4n.
        var looped = [UInt8](SyntheticCFB.build([("big", [UInt8](repeating: 9, count: 5000))]))
        looped.replaceSubrange(516..<520, with: SyntheticCFB.le32(1))       // the directory chain points at itself
        #expect(throws: CFBError.self) { try CFBFile(data: Data(looped)) }

        // A stream chain that ends before the stream's declared size.
        var short = [UInt8](SyntheticCFB.build([("big", [UInt8](repeating: 9, count: 5000))]))
        short.replaceSubrange((512 + 4 * 3)..<(516 + 4 * 3), with: SyntheticCFB.le32(SyntheticCFB.endOfChain))
        let cfb = try CFBFile(data: Data(short))
        #expect(throws: CFBError.self) { try cfb.stream(named: "big") }
    }
}

// MARK: - EMB

@Suite("EMB reader")
struct EMBReaderTests {

    @Test("Reads the design information")
    func designInfo() throws {
        let d = try EMBReader.parse(data: SyntheticEMB.build())
        #expect(d.stitchCount == 2143)
        #expect(d.trimCount == 4)
        #expect(d.colorCount == 2)
        #expect(d.stopCount == 2)
        #expect(d.colorChangeCount == 1)
        #expect(d.objectCount == 6)
        // 1/180 mm per unit.
        #expect(abs(d.widthMM - SyntheticEMB.width / 180) < 1e-9)
        #expect(abs(d.heightMM - SyntheticEMB.height / 180) < 1e-9)
        #expect(d.machineFormat == "Tajima TBF")
        #expect(d.source == "Native design")
        #expect(d.colorway == "Colorway 1")
        #expect(abs((d.threadLengthMM ?? 0) - 2_506_695.0 / 180) < 1e-6)
        #expect(abs((d.bobbinLengthMM ?? 0) - 1_017_395.0 / 180) < 1e-6)
    }

    @Test("Reads the thread list with names and colours")
    func threads() throws {
        let d = try EMBReader.parse(data: SyntheticEMB.build())
        #expect(d.threads.count == 2)
        #expect(d.threads[0].name == "R0 G0 B0")
        #expect(d.threads[0].hexString == "#000000")
        #expect(d.threads[1].name == "Dark Green")
        #expect(d.threads[1].chart == "Default")
        #expect(d.threads[1].code == 1801)
        #expect(d.threads[1].paletteSlot == 3)
        // COLORREF is 0x00BBGGRR.
        #expect((d.threads[1].red, d.threads[1].green, d.threads[1].blue) == (0x40, 0x80, 0x20))
        #expect(d.threads[1].hexString == "#408020")
    }

    @Test("Inflates both previews, stored and compressed")
    func previews() throws {
        let d = try EMBReader.parse(data: SyntheticEMB.build())
        #expect(d.designIconBMP.map { [UInt8]($0) } == SyntheticEMB.bmp)
        let jpeg = try #require(d.trueViewJPEG)
        #expect(jpeg.count >= 6000)
        #expect(Array(jpeg.prefix(4)) == [0xFF, 0xD8, 0xFF, 0xE0])
    }

    @Test("The picture decodes, falling back to the small icon")
    func image() throws {
        // The fake JPEG is not decodable, so this exercises the fallback to the BMP.
        let d = try EMBReader.parse(data: SyntheticEMB.build())
        let image = try #require(EMBRenderer.previewImage(for: d))
        #expect(image.width == 2 && image.height == 2)
    }

    @Test("A file without previews still reads")
    func noPreviews() throws {
        let d = try EMBReader.parse(data: SyntheticEMB.build(withPreviews: false))
        #expect(d.stitchCount == 2143)
        #expect(d.designIconBMP == nil && d.trueViewJPEG == nil)
        #expect(EMBRenderer.previewImage(for: d) == nil)
    }

    @Test("A compound file that is not an EMB is refused")
    func notEMB() {
        let other = SyntheticCFB.build([("WordDocument", [1, 2, 3])])
        #expect(throws: EMBError.self) { try EMBReader.parse(data: other) }
        #expect(throws: EMBError.self) { try EMBReader.parse(data: Data("hello".utf8)) }
    }

    @Test("A bad zlib stream is an error, not a crash")
    func badZlib() {
        #expect(throws: EMBError.self) { try Inflate.zlib([1, 2, 3, 4, 5, 6, 7, 8], expectedSize: 4) }
        #expect(throws: EMBError.self) { try Inflate.zlib(SyntheticEMB.zlibStored([1, 2, 3]), expectedSize: 4) }
        #expect(throws: EMBError.self) { try Inflate.zlib(SyntheticEMB.zlibStored([1, 2, 3]), expectedSize: 1 << 40) }
        #expect(throws: EMBError.self) { try Inflate.zlib(SyntheticEMB.zlibStored([1, 2, 3]), expectedSize: 0) }
        #expect(throws: Never.self) { try Inflate.zlib(SyntheticEMB.zlibStored([1, 2, 3]), expectedSize: 3) }
    }

    @Test("The design stream is never asked for")
    func neverTouchesDesignStream() throws {
        // `DesignDocument` is encrypted. Parsing must give the same answer with that stream
        // deleted outright, which can only be true if nothing depends on it.
        let withIt = try EMBReader.parse(data: SyntheticEMB.build())
        let without = try EMBReader.parse(data: SyntheticEMB.build(withDesignStream: false))
        #expect(withIt.stitchCount == without.stitchCount)
        #expect(withIt.threads == without.threads)
        #expect(withIt.trueViewJPEG == without.trueViewJPEG)
        let source = try String(contentsOf: URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/StitchKit/EMBReader.swift"), encoding: .utf8)
        #expect(!source.contains("stream(named: \"DesignDocument\")"))
    }

    @Test("Info rows read well")
    func infoRows() throws {
        let d = try EMBReader.parse(data: SyntheticEMB.build())
        let rows = Dictionary(uniqueKeysWithValues: d.infoRows.map { ($0.label, $0.value) })
        #expect(rows["Size"]?.hasPrefix("63.8 × 49.5 mm") == true)
        #expect(rows["Objects"] == "6")
        #expect(rows["Machine format"] == "Tajima TBF")
    }
}

// MARK: - Rendering

@Suite("EMB rendering")
struct EMBRenderingTests {

    /// 64 x 64: flat grey with a white band across the middle, as Wilcom pads a wide design.
    private func paddedImage() -> CGImage {
        let context = CGContext(
            data: nil, width: 64, height: 64, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        context.setFillColor(CGColor(srgbRed: 221 / 255, green: 221 / 255, blue: 221 / 255, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 64, height: 64))
        context.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 20, width: 64, height: 24))
        return context.makeImage()!
    }

    @Test("The grey padding is trimmed off")
    func trimsPadding() {
        let image = EMBRenderer.trimmed(paddedImage())
        #expect(image.width == 64)
        #expect(image.height == 24)
    }

    @Test("An image with no grey corner is left alone")
    func keepsFullImage() {
        let context = CGContext(
            data: nil, width: 32, height: 32, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        context.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 32, height: 32))
        let image = context.makeImage()!
        let result = EMBRenderer.trimmed(image)
        #expect(result.width == 32 && result.height == 32)
    }

    @Test("The preview draws something, and with no picture or threads still draws")
    func previewDraws() throws {
        var d = try EMBReader.parse(data: SyntheticEMB.build())
        for withThreads in [true, false] {
            if !withThreads { d.threads = [] }
            let size = EMBRenderer.previewSize
            let context = try #require(CGContext(
                data: nil, width: Int(size.width), height: Int(size.height), bitsPerComponent: 8, bytesPerRow: 0,
                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ))
            EMBRenderer.renderPreview(d, image: EMBRenderer.previewImage(for: d), title: "Sample", into: context, size: size)
            let image = try #require(context.makeImage())
            #expect(image.width == Int(size.width))
        }
    }

    @Test("Thumbnail size keeps the picture's aspect")
    func fitted() throws {
        let image = paddedImage()                         // 64 x 64
        let size = EMBRenderer.fittedSize(for: image, max: CGSize(width: 128, height: 64))
        #expect(size == CGSize(width: 64, height: 64))
    }
}

// MARK: - Real files (private; opt-in)

@Suite("EMB real samples")
struct EMBSampleTests {

    /// Set STITCHPEEK_EMB_SAMPLES to a file or folder of .emb files. They are never committed.
    static let paths: [URL] = {
        guard let raw = ProcessInfo.processInfo.environment["STITCHPEEK_EMB_SAMPLES"], !raw.isEmpty else { return [] }
        let root = URL(fileURLWithPath: (raw as NSString).expandingTildeInPath)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: root.path, isDirectory: &isDirectory) else { return [] }
        if !isDirectory.boolValue { return [root] }
        let walker = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)
        return (walker?.allObjects as? [URL] ?? []).filter { $0.pathExtension.lowercased() == "emb" }.sorted { $0.path < $1.path }
    }()

    @Test("Real files parse and render", .enabled(if: !EMBSampleTests.paths.isEmpty))
    func realFiles() throws {
        for url in Self.paths.prefix(40) {
            let d = try EMBReader.parse(contentsOf: url)
            #expect(d.stitchCount > 0)
            #expect(d.widthMM > 0 && d.heightMM > 0)
            #expect(!d.threads.isEmpty)
            #expect(Array(try #require(d.trueViewJPEG).prefix(3)) == [0xFF, 0xD8, 0xFF])
            #expect(EMBRenderer.previewImage(for: d) != nil)
        }
    }
}
