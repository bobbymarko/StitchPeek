import Foundation

/// The 512-byte ASCII header at the front of a DST file.
///
/// Parsed defensively and used only for the design name, thread colors, and as a
/// sanity check. Geometry always comes from the decoded stitches — plenty of
/// real-world files have short, malformed, or non-ASCII headers.
public struct DSTHeader: Sendable, Equatable {
    /// Every `XX:value` pair found, last-wins for repeated tags.
    public var fields: [String: String]

    /// `LA` — design name, 8 chars space-padded in well-formed files.
    public var label: String?
    /// `ST` — total *record* count. Includes jumps and color changes, so this is
    /// not the stitch count, and a parser's stitch count legitimately differs.
    public var recordCount: Int?
    /// `CO` — number of color *changes*. Blocks are usually this + 1.
    public var colorChanges: Int?

    /// `+X` `-X` `+Y` `-Y` — extent magnitudes, unsigned, in 0.1 mm units.
    /// `minusX`/`minusY` are absolute values of the negative extents.
    public var plusX: Int?
    public var minusX: Int?
    public var plusY: Int?
    public var minusY: Int?

    /// `AX` `AY` — signed end-of-design offset, 0.1 mm.
    public var ax: Int?
    public var ay: Int?
    /// `MX` `MY` — multi-design offset, usually 0.
    public var mx: Int?
    public var my: Int?

    /// `PD` — previous design, usually `******`.
    public var previousDesign: String?
    /// `AU` / `CP` — non-standard but common.
    public var author: String?
    public var copyright: String?

    /// `TC:hex,description,catalog` entries, in file order. Usually absent.
    public var threadColors: [StitchColor]

    public init(
        fields: [String: String] = [:],
        label: String? = nil,
        recordCount: Int? = nil,
        colorChanges: Int? = nil,
        plusX: Int? = nil,
        minusX: Int? = nil,
        plusY: Int? = nil,
        minusY: Int? = nil,
        ax: Int? = nil,
        ay: Int? = nil,
        mx: Int? = nil,
        my: Int? = nil,
        previousDesign: String? = nil,
        author: String? = nil,
        copyright: String? = nil,
        threadColors: [StitchColor] = []
    ) {
        self.fields = fields
        self.label = label
        self.recordCount = recordCount
        self.colorChanges = colorChanges
        self.plusX = plusX
        self.minusX = minusX
        self.plusY = plusY
        self.minusY = minusY
        self.ax = ax
        self.ay = ay
        self.mx = mx
        self.my = my
        self.previousDesign = previousDesign
        self.author = author
        self.copyright = copyright
        self.threadColors = threadColors
    }

    /// Tags that make a blob of bytes recognizable as a DST header.
    private static let signatureTags: Set<String> = ["LA", "ST", "CO", "+X", "-X", "+Y", "-Y", "AX", "AY", "PD"]

    /// Parses the leading header bytes. Returns `nil` when `data` carries none of the
    /// known tags — a garbage or overwritten header, which is not fatal.
    ///
    /// - Parameter data: the whole file, or at least its first bytes. Only the first
    ///   512 are considered.
    public static func parse(_ data: Data) -> DSTHeader? {
        let slice = data.prefix(512)
        guard !slice.isEmpty else { return nil }

        // The header ends at the 0x1A (SUB) terminator; everything after is padding.
        let body: Data
        if let subIndex = slice.firstIndex(of: 0x1A) {
            body = slice[slice.startIndex..<subIndex]
        } else {
            body = Data(slice)
        }

        // Lossy on purpose — non-ASCII bytes in a header must not lose us the good fields.
        let text = String(decoding: body, as: UTF8.self)

        var header = DSTHeader()
        var matchedSignature = false

        // Fields are \r-separated, but tolerate files that use \n or \r\n.
        let lines = text.split(whereSeparator: { $0 == "\r" || $0 == "\n" })
        for line in lines {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let tag = String(line[line.startIndex..<colon]).trimmingCharacters(in: .whitespaces)
            let value = String(line[line.index(after: colon)...])
            guard !tag.isEmpty else { continue }

            if Self.signatureTags.contains(tag) { matchedSignature = true }

            if tag == "TC" {
                if let color = Self.parseThreadColor(value) { header.threadColors.append(color) }
                // TC may repeat; keep the last one in `fields` but all of them in threadColors.
            }
            header.fields[tag] = value.trimmingCharacters(in: .whitespaces)
        }

        guard matchedSignature else { return nil }

        func int(_ tag: String) -> Int? {
            guard var s = header.fields[tag] else { return nil }
            s = s.replacingOccurrences(of: " ", with: "")
            if s.hasPrefix("+") { s.removeFirst() }
            return Int(s)
        }

        header.label = header.fields["LA"]
        header.recordCount = int("ST")
        header.colorChanges = int("CO")
        header.plusX = int("+X").map { abs($0) }
        header.minusX = int("-X").map { abs($0) }
        header.plusY = int("+Y").map { abs($0) }
        header.minusY = int("-Y").map { abs($0) }
        header.ax = int("AX")
        header.ay = int("AY")
        header.mx = int("MX")
        header.my = int("MY")
        header.previousDesign = header.fields["PD"]
        header.author = header.fields["AU"]
        header.copyright = header.fields["CP"]
        return header
    }

    /// `TC:hex,description,catalog`
    private static func parseThreadColor(_ value: String) -> StitchColor? {
        let parts = value.split(separator: ",", maxSplits: 2, omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
        guard let hex = parts.first else { return nil }
        let name = parts.count > 1 && !parts[1].isEmpty ? parts[1] : nil
        let catalog = parts.count > 2 && !parts[2].isEmpty ? parts[2] : nil
        return StitchColor(hex: hex, name: name, catalogNumber: catalog)
    }
}
