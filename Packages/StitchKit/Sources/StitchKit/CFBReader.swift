import Foundation

/// Why a compound file could not be read.
public enum CFBError: Error, Equatable, LocalizedError {
    case notCompoundFile
    case unsupported(String)
    case corrupt(String)
    case streamNotFound(String)

    public var errorDescription: String? {
        switch self {
        case .notCompoundFile: return "Not an OLE2 compound file."
        case .unsupported(let why): return "Unsupported compound file: \(why)."
        case .corrupt(let why): return "Damaged compound file: \(why)."
        case .streamNotFound(let name): return "Stream not found: \(name)."
        }
    }
}

/// A minimal reader for Microsoft Compound File Binary (OLE2/CFB) containers, which is what a
/// Wilcom `.emb` is. Read-only, and written to the public [MS-CFB] layout: header, FAT,
/// DIFAT, mini-FAT, directory.
///
/// It only ever reads the directory and the streams a caller asks for by name. Nothing here
/// knows or cares what is in a stream, so an unreadable (encrypted) one is simply never asked
/// for.
///
/// Every offset and chain is bounds-checked and chains are cycle-limited: a damaged or hostile
/// file throws `CFBError`; it never traps. (A trap in a Quick Look extension gets the extension
/// throttled and then silently disabled.)
public struct CFBFile: Sendable {

    public struct Entry: Sendable, Equatable {
        /// Full path from the root, `/`-separated. Almost always just the name.
        public let path: String
        public let name: String
        /// 1 storage, 2 stream, 5 root.
        public let type: UInt8
        public let startSector: UInt32
        public let size: UInt64
    }

    private static let signature: [UInt8] = [0xD0, 0xCF, 0x11, 0xE0, 0xA1, 0xB1, 0x1A, 0xE1]
    private static let endOfChain: UInt32 = 0xFFFF_FFFE
    /// Sector numbers at or above this are markers (free, end of chain, FAT, DIFAT), not data.
    private static let maxRegularSector: UInt32 = 0xFFFF_FFFA
    private static let noStream: UInt32 = 0xFFFF_FFFF
    /// Streams are refused above this, so a lying size field cannot ask for gigabytes.
    private static let maxStreamBytes = 256 << 20

    private let bytes: [UInt8]
    private let sectorSize: Int
    private let miniSectorSize: Int
    private let miniCutoff: UInt64
    private let fat: [UInt32]
    private let miniFAT: [UInt32]
    private let miniStream: [UInt8]
    /// Every stream (type 2) in the directory.
    public let streams: [Entry]

    public init(data: Data) throws {
        let b = [UInt8](data)
        guard b.count >= 512, Array(b[0..<8]) == Self.signature else { throw CFBError.notCompoundFile }
        bytes = b

        let major = try Self.u16(b, 0x1A)
        guard major == 3 || major == 4 else { throw CFBError.unsupported("version \(major)") }
        guard try Self.u16(b, 0x1C) == 0xFFFE else { throw CFBError.unsupported("big-endian") }
        let sectorShift = try Self.u16(b, 0x1E)
        let miniShift = try Self.u16(b, 0x20)
        guard sectorShift == 9 || sectorShift == 12, (major == 3) == (sectorShift == 9) else {
            throw CFBError.corrupt("sector size")
        }
        guard miniShift == 6 else { throw CFBError.corrupt("mini sector size") }
        let sectorSize = 1 << sectorShift
        self.sectorSize = sectorSize
        miniSectorSize = 1 << miniShift

        let fatSectorCount = Int(try Self.u32(b, 0x2C))
        let firstDirectory = try Self.u32(b, 0x30)
        miniCutoff = UInt64(try Self.u32(b, 0x38))
        let firstMiniFAT = try Self.u32(b, 0x3C)
        let miniFATCount = Int(try Self.u32(b, 0x40))
        var difatSector = try Self.u32(b, 0x44)
        let difatCount = Int(try Self.u32(b, 0x48))

        // The most sectors the file can physically hold; bounds every count below.
        let sectorLimit = b.count / sectorSize + 1
        guard fatSectorCount <= sectorLimit, miniFATCount <= sectorLimit, difatCount <= sectorLimit else {
            throw CFBError.corrupt("sector counts")
        }

        // DIFAT: the first 109 FAT sector numbers live in the header, the rest in a chain.
        var fatSectors: [UInt32] = []
        for i in 0..<109 {
            let s = try Self.u32(b, 0x4C + 4 * i)
            if s < Self.maxRegularSector { fatSectors.append(s) }
        }
        var difatSeen = 0
        while difatSector < Self.maxRegularSector, difatSeen < difatCount {
            let base = try Self.sectorOffset(difatSector, sectorSize: sectorSize, total: b.count)
            for i in 0..<(sectorSize / 4 - 1) {
                let s = try Self.u32(b, base + 4 * i)
                if s < Self.maxRegularSector { fatSectors.append(s) }
            }
            difatSector = try Self.u32(b, base + sectorSize - 4)
            difatSeen += 1
        }
        guard fatSectors.count >= min(fatSectorCount, 1) else { throw CFBError.corrupt("no FAT") }

        var fat: [UInt32] = []
        fat.reserveCapacity(fatSectors.count * sectorSize / 4)
        for s in fatSectors {
            let base = try Self.sectorOffset(s, sectorSize: sectorSize, total: b.count)
            for i in 0..<(sectorSize / 4) { fat.append(try Self.u32(b, base + 4 * i)) }
        }
        self.fat = fat

        // Directory.
        let dirBytes = try Self.readChain(b, start: firstDirectory, fat: fat, sectorSize: sectorSize)
        guard dirBytes.count >= 128 else { throw CFBError.corrupt("empty directory") }
        let entryCount = dirBytes.count / 128

        struct Raw {
            var name: String
            var type: UInt8
            var left: UInt32, right: UInt32, child: UInt32
            var start: UInt32
            var size: UInt64
        }
        var raws: [Raw] = []
        raws.reserveCapacity(entryCount)
        for i in 0..<entryCount {
            let o = i * 128
            let nameBytes = min(Int(try Self.u16(dirBytes, o + 64)), 64)
            let units = max(0, nameBytes / 2 - 1)           // the stored length counts the NUL
            var scalars: [UInt16] = []
            for u in 0..<units { scalars.append(UInt16(try Self.u16(dirBytes, o + 2 * u))) }
            // Version 3 files only define the low 32 bits of the size.
            var size = UInt64(try Self.u32(dirBytes, o + 120))
            if major == 4 { size |= UInt64(try Self.u32(dirBytes, o + 124)) << 32 }
            raws.append(Raw(
                name: String(decoding: scalars, as: UTF16.self),
                type: dirBytes[o + 66],
                left: try Self.u32(dirBytes, o + 68),
                right: try Self.u32(dirBytes, o + 72),
                child: try Self.u32(dirBytes, o + 76),
                start: try Self.u32(dirBytes, o + 116),
                size: size
            ))
        }
        guard raws[0].type == 5 else { throw CFBError.corrupt("no root entry") }

        // Walk the sibling tree under the root (and any storages), collecting streams. The
        // visited set also stops a cyclic tree.
        var found: [Entry] = []
        var visited = Set<Int>()
        // An explicit stack, not recursion: a hostile file can chain tens of thousands of siblings.
        var pending: [(id: UInt32, prefix: String)] = [(raws[0].child, "")]
        while let (id, prefix) = pending.popLast() {
            guard id != Self.noStream, Int(id) < raws.count, !visited.contains(Int(id)) else { continue }
            visited.insert(Int(id))
            let r = raws[Int(id)]
            pending.append((r.right, prefix))
            pending.append((r.left, prefix))
            let path = prefix.isEmpty ? r.name : prefix + "/" + r.name
            if r.type == 2 {
                found.append(Entry(path: path, name: r.name, type: 2, startSector: r.start, size: r.size))
            } else if r.type == 1 {
                pending.append((r.child, path))
            }
        }
        streams = found

        // Mini stream: the root entry's own data holds every stream below the cutoff.
        let root = raws[0]
        if miniFATCount > 0, firstMiniFAT < Self.maxRegularSector {
            let table = try Self.readChain(b, start: firstMiniFAT, fat: fat, sectorSize: sectorSize)
            var mini: [UInt32] = []
            mini.reserveCapacity(table.count / 4)
            for i in 0..<(table.count / 4) { mini.append(try Self.u32(table, 4 * i)) }
            miniFAT = mini
            let container = try Self.readChain(b, start: root.start, fat: fat, sectorSize: sectorSize)
            miniStream = UInt64(container.count) > root.size ? Array(container[0..<Int(root.size)]) : container
        } else {
            miniFAT = []
            miniStream = []
        }
    }

    public var streamNames: [String] { streams.map(\.path) }

    public func hasStream(named name: String) -> Bool {
        streams.contains { $0.path == name }
    }

    /// The bytes of one stream, looked up by its path (for a root-level stream, its name; Wilcom
    /// names carry a leading U+0005 control character, which must be included).
    public func stream(named name: String) throws -> [UInt8] {
        guard let entry = streams.first(where: { $0.path == name }) else {
            throw CFBError.streamNotFound(name)
        }
        guard entry.size <= UInt64(Self.maxStreamBytes) else { throw CFBError.corrupt("stream size") }
        let size = Int(entry.size)
        if size == 0 { return [] }

        if entry.size < miniCutoff {
            var out: [UInt8] = []
            out.reserveCapacity(size)
            var s = entry.startSector
            var hops = 0
            while s < Self.maxRegularSector, out.count < size {
                hops += 1
                guard hops <= miniFAT.count + 1, Int(s) < miniFAT.count else { throw CFBError.corrupt("mini chain") }
                let o = Int(s) * miniSectorSize
                guard o + miniSectorSize <= miniStream.count else { throw CFBError.corrupt("mini sector range") }
                out.append(contentsOf: miniStream[o..<(o + miniSectorSize)])
                s = miniFAT[Int(s)]
            }
            guard out.count >= size else { throw CFBError.corrupt("short mini stream") }
            return Array(out[0..<size])
        }

        let out = try Self.readChain(bytes, start: entry.startSector, fat: fat, sectorSize: sectorSize, limit: size)
        guard out.count >= size else { throw CFBError.corrupt("short stream") }
        return Array(out[0..<size])
    }

    // MARK: Helpers

    private static func sectorOffset(_ sector: UInt32, sectorSize: Int, total: Int) throws -> Int {
        let o = (Int(sector) + 1) * sectorSize
        guard o >= 0, o + sectorSize <= total else { throw CFBError.corrupt("sector \(sector) outside the file") }
        return o
    }

    /// Follows a FAT chain, concatenating sectors. Stops after `limit` bytes when given.
    private static func readChain(
        _ b: [UInt8], start: UInt32, fat: [UInt32], sectorSize: Int, limit: Int? = nil
    ) throws -> [UInt8] {
        var out: [UInt8] = []
        var s = start
        var hops = 0
        while s < maxRegularSector {
            hops += 1
            guard hops <= fat.count + 1, Int(s) < fat.count else { throw CFBError.corrupt("chain") }
            let o = try sectorOffset(s, sectorSize: sectorSize, total: b.count)
            out.append(contentsOf: b[o..<(o + sectorSize)])
            if let limit, out.count >= limit { break }
            s = fat[Int(s)]
        }
        return out
    }

    static func u16(_ b: [UInt8], _ o: Int) throws -> Int {
        guard o >= 0, o + 2 <= b.count else { throw CFBError.corrupt("read past end") }
        return Int(b[o]) | Int(b[o + 1]) << 8
    }

    static func u32(_ b: [UInt8], _ o: Int) throws -> UInt32 {
        guard o >= 0, o + 4 <= b.count else { throw CFBError.corrupt("read past end") }
        return UInt32(b[o]) | UInt32(b[o + 1]) << 8 | UInt32(b[o + 2]) << 16 | UInt32(b[o + 3]) << 24
    }
}
