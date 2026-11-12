import Compression
import CoreGraphics
import Foundation

// MARK: - Model

/// One thread stop from an EMB's colour sequence.
public struct EMBThread: Sendable, Hashable {
    /// Position in the stitching order, 0-based.
    public var stop: Int
    public var paletteSlot: Int
    /// Numeric thread code from the file.
    public var code: Int
    /// Thread name, or `R245 G215 B23` when the colour has none.
    public var name: String
    /// Thread chart / brand (`Default`, or empty).
    public var chart: String
    public var red: UInt8
    public var green: UInt8
    public var blue: UInt8

    public var color: StitchColor {
        StitchColor(
            red: Double(red) / 255, green: Double(green) / 255, blue: Double(blue) / 255,
            name: name.isEmpty ? nil : name,
            catalogNumber: code == 0 ? nil : String(code)
        )
    }

    public var hexString: String { String(format: "#%02X%02X%02X", Int(red), Int(green), Int(blue)) }
}

/// What can be read from a Wilcom `.emb` without its design stream: the design-info block and
/// the two embedded previews.
///
/// The stitches and objects live in the `DesignDocument` stream, which is encrypted and which
/// this reader never touches. So there is no stitch geometry here; the picture is the preview
/// image Wilcom's software rendered into the file.
public struct EMBDesign: Sendable {
    /// EmbroideryStudio's internal unit is 1/180 mm.
    public static let unitsPerMM = 180.0

    public var stitchCount: Int
    public var trimCount: Int
    public var colorCount: Int
    public var stopCount: Int
    public var colorChangeCount: Int
    public var objectCount: Int
    public var widthMM: Double
    public var heightMM: Double
    /// Top thread, mm. `nil` when the file does not say.
    public var threadLengthMM: Double?
    public var bobbinLengthMM: Double?
    /// e.g. `Tajima TBF`.
    public var machineFormat: String?
    /// e.g. `Native design`.
    public var source: String?
    public var colorway: String?
    public var threads: [EMBThread]
    /// Decompressed `DESIGN_ICON`: a small BMP.
    public var designIconBMP: Data?
    /// Decompressed `TRUEVIEW_ICON`: a 256 x 256 JPEG.
    public var trueViewJPEG: Data?

    public var widthInches: Double { widthMM / 25.4 }
    public var heightInches: Double { heightMM / 25.4 }
}

public enum EMBError: Error, Equatable, LocalizedError {
    case notEMB(String)
    case badPreview(String)

    public var errorDescription: String? {
        switch self {
        case .notEMB(let why): return "Not a readable EMB file: \(why)."
        case .badPreview(let why): return "The EMB's preview could not be read: \(why)."
        }
    }
}

// MARK: - Reader

public enum EMBReader {

    public static let designInfoStream = "\u{05}WilcomDesignInformationDDD"
    public static let designIconStream = "DESIGN_ICON"
    public static let trueViewStream = "TRUEVIEW_ICON"

    /// Bytes per thread record in the `sequence list` blob.
    static let sequenceRecordSize = 796

    public static func parse(contentsOf url: URL) throws -> EMBDesign {
        try parse(data: Data(contentsOf: url, options: .mappedIfSafe))
    }

    public static func parse(data: Data) throws -> EMBDesign {
        let cfb: CFBFile
        do { cfb = try CFBFile(data: data) } catch let e as CFBError { throw EMBError.notEMB(e.localizedDescription) }

        guard cfb.hasStream(named: designInfoStream) else {
            throw EMBError.notEMB("no Wilcom design information")
        }
        let props = try PropertySet(bytes: try cfb.stream(named: designInfoStream))

        func int(_ name: String, _ id: Int) -> Int { props.number(name, id).map { Int($0.rounded()) } ?? 0 }
        let width = props.number("design width", 17) ?? 0
        let height = props.number("design height", 16) ?? 0
        let u = EMBDesign.unitsPerMM

        var threads: [EMBThread] = []
        if case .blob(let seq)? = props.value("sequence list", 18) {
            threads = parseSequence(seq)
        }

        // The previews are optional: a damaged one costs the picture, not the whole file.
        let bmp = try? previewStream(cfb, designIconStream)
        let jpeg = try? previewStream(cfb, trueViewStream)

        return EMBDesign(
            stitchCount: int("number of stitches", 6),
            trimCount: int("number of trims", 5),
            colorCount: int("number of colours", 3),
            stopCount: int("number of stops", 4),
            colorChangeCount: int("number of colour changes", 27),
            objectCount: int("number of objects", 7),
            widthMM: width / u,
            heightMM: height / u,
            threadLengthMM: props.number("thread length", 8).map { $0 / u },
            bobbinLengthMM: props.number("bobbin length", 9).map { $0 / u },
            machineFormat: props.string("embroidery machine name", 19),
            source: props.string("source", 43),
            colorway: props.string("colorway", 33),
            threads: threads,
            designIconBMP: bmp.map { Data($0) },
            trueViewJPEG: jpeg.map { Data($0) }
        )
    }

    // MARK: Sequence list

    static func parseSequence(_ b: [UInt8]) -> [EMBThread] {
        var out: [EMBThread] = []
        for i in 0..<(b.count / sequenceRecordSize) {
            let r = i * sequenceRecordSize
            guard let stop = try? CFBFile.u32(b, r), let slot = try? CFBFile.u32(b, r + 4),
                  let code = try? CFBFile.u32(b, r + 8), let ref = try? CFBFile.u32(b, r + 792)
            else { break }
            out.append(EMBThread(
                stop: Int(stop), paletteSlot: Int(slot), code: Int(code),
                name: cString(b, r + 20, 256), chart: cString(b, r + 276, 256),
                red: UInt8(ref & 0xFF), green: UInt8((ref >> 8) & 0xFF), blue: UInt8((ref >> 16) & 0xFF)
            ))
        }
        return out
    }

    /// Text up to the first NUL, as Windows-1252.
    static func cString(_ b: [UInt8], _ start: Int, _ length: Int) -> String {
        guard start >= 0, start < b.count else { return "" }
        let slice = b[start..<min(b.count, start + length)]
        let text = slice.prefix { $0 != 0 }
        return windows1252(text)
    }

    /// Windows-1252 by hand. Foundation's `.windowsCP1252` is not available on every platform
    /// (it is missing in swift-corelibs-foundation, where it silently returned nil).
    static func windows1252<S: Sequence>(_ bytes: S) -> String where S.Element == UInt8 {
        // 0x80...0x9F differ from Latin-1; the five undefined slots map to U+FFFD.
        let high: [UInt32] = [
            0x20AC, 0xFFFD, 0x201A, 0x0192, 0x201E, 0x2026, 0x2020, 0x2021, 0x02C6, 0x2030, 0x0160, 0x2039, 0x0152, 0xFFFD, 0x017D, 0xFFFD,
            0xFFFD, 0x2018, 0x2019, 0x201C, 0x201D, 0x2022, 0x2013, 0x2014, 0x02DC, 0x2122, 0x0161, 0x203A, 0x0153, 0xFFFD, 0x017E, 0x0178,
        ]
        var out = String.UnicodeScalarView()
        for b in bytes {
            let v: UInt32 = (0x80...0x9F).contains(b) ? high[Int(b) - 0x80] : UInt32(b)
            out.append(Unicode.Scalar(v) ?? "\u{FFFD}")
        }
        return String(out)
    }

    // MARK: Previews

    /// `u32 uncompressed length` + a zlib stream.
    static func previewStream(_ cfb: CFBFile, _ name: String) throws -> [UInt8] {
        let raw = try cfb.stream(named: name)
        guard raw.count > 4 else { throw EMBError.badPreview("\(name) is empty") }
        let expected = Int(try CFBFile.u32(raw, 0))
        return try Inflate.zlib(Array(raw[4...]), expectedSize: expected)
    }
}

// MARK: - zlib

enum Inflate {
    /// Upper bound on a decompressed preview, so a lying length prefix cannot ask for gigabytes.
    static let maxOutput = 64 << 20

    /// Decodes a zlib stream (RFC 1950) of known uncompressed size.
    ///
    /// Apple's `COMPRESSION_ZLIB` is *raw* deflate, so the 2-byte zlib header and the trailing
    /// Adler-32 are stripped here.
    static func zlib(_ input: [UInt8], expectedSize: Int) throws -> [UInt8] {
        guard expectedSize > 0, expectedSize <= maxOutput else { throw EMBError.badPreview("bad length") }
        guard input.count > 6, input[0] & 0x0F == 8, (Int(input[0]) << 8 | Int(input[1])) % 31 == 0,
              input[1] & 0x20 == 0
        else { throw EMBError.badPreview("not a zlib stream") }

        let deflate = Array(input[2..<(input.count - 4)])
        var out = [UInt8](repeating: 0, count: expectedSize)
        let written = deflate.withUnsafeBufferPointer { src in
            out.withUnsafeMutableBufferPointer { dst in
                compression_decode_buffer(
                    dst.baseAddress!, expectedSize, src.baseAddress!, deflate.count, nil, COMPRESSION_ZLIB
                )
            }
        }
        guard written == expectedSize else { throw EMBError.badPreview("decompressed \(written) of \(expectedSize) bytes") }
        return out
    }
}

// MARK: - Property set

/// The subset of an OLE property set that Wilcom's design-info stream uses, including the
/// name dictionary (property 0) that generic readers skip.
struct PropertySet {
    enum Value {
        case int(Int)
        case double(Double)
        case string(String)
        case blob([UInt8])
    }

    private var byID: [Int: Value] = [:]
    private var idForName: [String: Int] = [:]

    init(bytes d: [UInt8]) throws {
        func bad(_ why: String) -> EMBError { .notEMB("design information: \(why)") }
        guard d.count >= 48 else { throw bad("too short") }
        // 28-byte header + one 20-byte FMTID/offset pair; the first section offset is at 44.
        let section = Int(try CFBFile.u32(d, 44))
        let count = Int(try CFBFile.u32(d, section + 4))
        guard count >= 0, count <= 4096, section + 8 + 8 * count <= d.count else { throw bad("bad section") }

        var offsets: [Int: Int] = [:]
        for i in 0..<count {
            let id = Int(try CFBFile.u32(d, section + 8 + 8 * i))
            offsets[id] = Int(try CFBFile.u32(d, section + 12 + 8 * i))
        }

        if let dict = offsets[0] {
            let names = Int(try CFBFile.u32(d, section + dict))
            var q = section + dict + 4
            for _ in 0..<min(names, 4096) {
                let id = Int(try CFBFile.u32(d, q))
                let len = Int(try CFBFile.u32(d, q + 4))
                q += 8
                guard len >= 0, q + len <= d.count else { throw bad("bad name") }
                let text = d[q..<(q + len)].prefix { $0 != 0 }
                idForName[EMBReader.windows1252(text).lowercased()] = id
                q += len
            }
        }

        for (id, off) in offsets where id != 0 && id != 1 {
            let a = section + off
            guard a >= 0, a + 4 <= d.count else { continue }
            let type = try CFBFile.u32(d, a)
            switch type {
            case 0x03:                                   // VT_I4
                byID[id] = .int(Int(Int32(bitPattern: try CFBFile.u32(d, a + 4))))
            case 0x02:                                   // VT_I2
                byID[id] = .int(Int(Int16(truncatingIfNeeded: try CFBFile.u16(d, a + 4))))
            case 0x05:                                   // VT_R8
                guard a + 12 <= d.count else { continue }
                var bits: UInt64 = 0
                for k in 0..<8 { bits |= UInt64(d[a + 4 + k]) << (8 * UInt64(k)) }
                byID[id] = .double(Double(bitPattern: bits))
            case 0x1E, 0x41:                             // VT_LPSTR, VT_BLOB
                let len = Int(try CFBFile.u32(d, a + 4))
                guard len >= 0, a + 8 + len <= d.count else { continue }
                let payload = Array(d[(a + 8)..<(a + 8 + len)])
                if type == 0x41 {
                    byID[id] = .blob(payload)
                } else {
                    let text = payload.prefix { $0 != 0 }
                    byID[id] = .string(EMBReader.windows1252(text))
                }
            default:
                continue
            }
        }
    }

    /// Looked up by the file's own field name; the property id is the fallback when the name
    /// dictionary is missing.
    func value(_ name: String, _ fallbackID: Int) -> Value? {
        byID[idForName[name.lowercased()] ?? fallbackID]
    }

    func number(_ name: String, _ id: Int) -> Double? {
        switch value(name, id) {
        case .int(let v)?: return Double(v)
        case .double(let v)?: return v
        default: return nil
        }
    }

    func string(_ name: String, _ id: Int) -> String? {
        if case .string(let s)? = value(name, id), !s.isEmpty { return s }
        return nil
    }
}

// MARK: - Display

extension EMBDesign {
    /// Label and value pairs for an info panel, in display order. Shared by the Quick Look
    /// preview and the viewer so the two always agree.
    public var infoRows: [(label: String, value: String)] {
        var rows: [(label: String, value: String)] = []
        rows.append(("Size", String(format: "%.1f × %.1f mm  (%.2f × %.2f in)", widthMM, heightMM, widthInches, heightInches)))
        rows.append(("Stitches", stitchCount.formatted()))
        rows.append(("Colors", colorCount.formatted() + (colorChangeCount > 0 ? "  ·  \(colorChangeCount) color change\(colorChangeCount == 1 ? "" : "s")" : "")))
        rows.append(("Trims", trimCount.formatted()))
        rows.append(("Objects", objectCount.formatted()))
        if let mm = threadLengthMM, mm > 0 {
            rows.append(("Thread", String(format: "%.1f m", mm / 1000)))
        }
        if let machineFormat { rows.append(("Machine format", machineFormat)) }
        return rows
    }
}
