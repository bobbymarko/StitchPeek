import AppKit
import CoreGraphics
import CryptoKit
import Foundation
import ImageIO
import StitchKit
import UniformTypeIdentifiers

// MARK: - Model

/// A mark on a design for the embroidery agent: a pin on one spot, or a box around an area,
/// each with its own note.
///
/// Positions are design units — 0.1 mm, the DST's own origin, +y **down** — which are exactly
/// the coordinates pyembroidery reports for the same file (checked stitch-for-stitch on
/// real designs). That makes position the handle an agent can trust; see `MarkupFile.about`.
struct Annotation: Identifiable, Equatable {
    enum Kind: String { case pin, region }

    let id: UUID
    let kind: Kind
    /// For a pin, a zero-size rect at the point; for a region, the standardized box.
    var rect: CGRect
    var note: String
    var author: String
    var created: Date

    var point: CGPoint { CGPoint(x: rect.midX, y: rect.midY) }

    static func pin(at point: CGPoint) -> Annotation {
        Annotation(id: UUID(), kind: .pin, rect: CGRect(origin: point.rounded, size: .zero),
                   note: "", author: currentAuthor(), created: Date())
    }

    static func region(_ rect: CGRect) -> Annotation {
        let r = rect.standardized
        let box = CGRect(x: r.minX.rounded(), y: r.minY.rounded(),
                         width: r.width.rounded(), height: r.height.rounded())
        return Annotation(id: UUID(), kind: .region, rect: box,
                          note: "", author: currentAuthor(), created: Date())
    }
}

/// Who made a mark: the account's name plus the Mac, since a shared account name alone
/// can't tell two people apart.
private func currentAuthor() -> String {
    let name = NSFullUserName()
    guard let computer = Host.current().localizedName, !computer.isEmpty else { return name }
    return "\(name) (\(computer))"
}

private extension CGPoint {
    var rounded: CGPoint { CGPoint(x: x.rounded(), y: y.rounded()) }
}

// MARK: - The sidecar file

/// `design.markup.json`, saved beside `design.dst`. Self-describing on purpose: whichever
/// agent reads it gets the coordinate conventions in the file itself.
struct MarkupFile: Codable {
    static let formatName = "stitchpeek-markup"

    var format = MarkupFile.formatName
    var version = 1
    var about: String
    var design: DesignInfo
    var picture: String
    var updated: Date
    var annotations: [Entry]

    struct DesignInfo: Codable {
        var file: String
        var sha256: String
        var stitches: Int
        var colorBlocks: Int
        var bounds: Box
        var widthMM: Double
        var heightMM: Double
    }

    struct Box: Codable {
        var minX: Int
        var minY: Int
        var maxX: Int
        var maxY: Int
    }

    struct Point: Codable {
        var x: Int
        var y: Int
    }

    struct Entry: Codable {
        var number: Int
        var id: String
        var kind: String
        var note: String
        var author: String
        var created: Date
        /// Pins.
        var at: Point?
        var nearestStitch: StitchRef?
        /// Regions.
        var region: Box?
        var stitchesInside: StitchRange?
    }

    struct StitchRef: Codable {
        var x: Int
        var y: Int
        var distanceMM: Double
        var stitchNumber: Int
        var colorBlock: Int
        var record: Int
        var byteOffset: Int
    }

    struct StitchRange: Codable {
        var count: Int
        var firstStitchNumber: Int?
        var lastStitchNumber: Int?
        var firstRecord: Int?
        var lastRecord: Int?
        var colorBlocks: [Int]
    }

    static func aboutText(pictureName: String) -> String {
        """
        Annotations made in StitchPeek on this embroidery design, for whoever fixes it. \
        Look at \(pictureName) first: the whole design with each annotation numbered, then a \
        close-up of each one. Every annotation has a note saying what is wrong. \
        Coordinates (x, y) are DST units — 0.1 mm — measured from the DST's own origin with \
        +x to the right and +y DOWN. They are exactly the coordinates pyembroidery.read_dst() \
        reports for this file, so match annotations to stitches by position. \
        "stitchNumber" counts needle-down stitches from 1 (StitchPeek's stitch scrubber). \
        "colorBlock" counts color blocks from 1. "record" is the 0-based index of the 3-byte \
        record after the 512-byte header (byteOffset = 512 + 3 × record); it is NOT \
        pyembroidery's stitch-list index, which merges runs of jumps into trims. \
        design.sha256 identifies the exact file that was annotated: if the .dst no longer \
        matches it, the design has changed since and positions may not line up.
        """
    }
}

// MARK: - Store

enum MarkupStore {
    static func jsonURL(for dst: URL) -> URL {
        dst.deletingPathExtension().appendingPathExtension("markup").appendingPathExtension("json")
    }

    static func pictureURL(for dst: URL) -> URL {
        dst.deletingPathExtension().appendingPathExtension("markup").appendingPathExtension("png")
    }

    struct Loaded {
        var annotations: [Annotation]
        /// The .dst has changed since these were made.
        var isStale: Bool
        /// The hash of the file the marks were made on.
        var annotatedSHA256: String
    }

    static func load(for dst: URL) -> Loaded? {
        guard let data = try? Data(contentsOf: jsonURL(for: dst)),
              let file = try? decoder.decode(MarkupFile.self, from: data),
              file.format == MarkupFile.formatName
        else { return nil }

        let annotations: [Annotation] = file.annotations.compactMap { entry in
            let id = UUID(uuidString: entry.id) ?? UUID()
            switch entry.kind {
            case "pin":
                guard let at = entry.at else { return nil }
                return Annotation(id: id, kind: .pin, rect: CGRect(x: at.x, y: at.y, width: 0, height: 0),
                                  note: entry.note, author: entry.author, created: entry.created)
            case "region":
                guard let box = entry.region else { return nil }
                return Annotation(id: id, kind: .region,
                                  rect: CGRect(x: box.minX, y: box.minY, width: box.maxX - box.minX, height: box.maxY - box.minY),
                                  note: entry.note, author: entry.author, created: entry.created)
            default:
                return nil
            }
        }
        let currentHash = (try? Data(contentsOf: dst)).map(sha256) ?? ""
        return Loaded(annotations: annotations, isStale: currentHash != file.design.sha256,
                      annotatedSHA256: file.design.sha256)
    }

    /// Writes the picture and then the JSON beside the design. With no annotations left,
    /// removes both instead.
    ///
    /// `annotatedSHA256` keeps the hash of the file the marks were originally made on while
    /// they are stale, so editing a note doesn't quietly vouch for marks that may be off.
    static func save(_ annotations: [Annotation], design: Design, dst: URL, annotatedSHA256: String? = nil) throws {
        guard !annotations.isEmpty else {
            remove(for: dst)
            return
        }
        guard let dstData = try? Data(contentsOf: dst) else {
            throw FeedbackError("Couldn't read \(dst.lastPathComponent) to save its markup.")
        }

        let analysis = MarkupAnalysis(data: dstData)
        let pictureURL = pictureURL(for: dst)
        let pictureName = pictureURL.lastPathComponent

        if let picture = MarkupPicture.render(design: design, annotations: annotations, title: dst.lastPathComponent),
           let png = FeedbackCapture.png(picture) {
            try png.write(to: pictureURL, options: .atomic)
        }

        let bounds = design.bounds
        let file = MarkupFile(
            about: MarkupFile.aboutText(pictureName: pictureName),
            design: .init(
                file: dst.lastPathComponent,
                sha256: annotatedSHA256 ?? sha256(dstData),
                stitches: design.stitchCount,
                colorBlocks: design.blocks.count,
                bounds: .init(minX: Int(bounds.minX), minY: Int(bounds.minY), maxX: Int(bounds.maxX), maxY: Int(bounds.maxY)),
                widthMM: (design.widthMM * 10).rounded() / 10,
                heightMM: (design.heightMM * 10).rounded() / 10
            ),
            picture: pictureName,
            updated: Date(),
            annotations: annotations.enumerated().map { index, annotation in
                var entry = MarkupFile.Entry(
                    number: index + 1,
                    id: annotation.id.uuidString,
                    kind: annotation.kind.rawValue,
                    note: annotation.note,
                    author: annotation.author,
                    created: annotation.created
                )
                switch annotation.kind {
                case .pin:
                    entry.at = .init(x: Int(annotation.point.x), y: Int(annotation.point.y))
                    entry.nearestStitch = analysis.nearestStitch(to: annotation.point)
                case .region:
                    let r = annotation.rect
                    entry.region = .init(minX: Int(r.minX), minY: Int(r.minY), maxX: Int(r.maxX), maxY: Int(r.maxY))
                    entry.stitchesInside = analysis.stitches(in: r)
                }
                return entry
            }
        )
        try encoder.encode(file).write(to: jsonURL(for: dst), options: .atomic)
    }

    /// Removes the sidecars — but only a JSON file this app wrote, never anything else that
    /// happens to share the name.
    static func remove(for dst: URL) {
        let json = jsonURL(for: dst)
        guard let data = try? Data(contentsOf: json),
              let file = try? decoder.decode(MarkupFile.self, from: data),
              file.format == MarkupFile.formatName
        else { return }
        try? FileManager.default.removeItem(at: json)
        try? FileManager.default.removeItem(at: pictureURL(for: dst))
    }

    /// Text to paste into the agent's chat. Self-contained: the notes are inline, and the
    /// paths say where the precise data and the picture are.
    static func agentPrompt(dst: URL, annotations: [Annotation]) -> String {
        var lines = [
            "Please fix the marked-up problems in this embroidery design:",
            dst.path,
            "",
            "Annotations: \(jsonURL(for: dst).path) (positions in DST units, 0.1 mm, +y down — the same coordinates pyembroidery reports)",
            "Picture: \(pictureURL(for: dst).path) (the design with each mark numbered, plus close-ups)",
            ""
        ]
        for (index, annotation) in annotations.enumerated() {
            let note = annotation.note.trimmingCharacters(in: .whitespacesAndNewlines)
            let what = annotation.kind == .pin ? "pin" : "boxed area"
            lines.append("\(index + 1). (\(what)) \(note.isEmpty ? "[no note]" : note)")
        }
        return lines.joined(separator: "\n")
    }

    static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()
}

// MARK: - Analysis

/// Walks the raw records once so each annotation can name the stitches it points at.
struct MarkupAnalysis {
    private struct Stitch {
        let x: Int
        let y: Int
        let record: Int
        let number: Int
        let block: Int
    }

    private let stitches: [Stitch]

    init(data: Data) {
        var stitches: [Stitch] = []
        var number = 0
        var block = 1
        var blockHasStitches = false
        for (record, r) in DSTParser.decodeRecords(data: data).enumerated() {
            switch r.command {
            case 0x03:
                number += 1
                blockHasStitches = true
                stitches.append(Stitch(x: r.x, y: r.y, record: record, number: number, block: block))
            case 0xC3:
                // Matches the parser and the inspector: an empty block is skipped, so
                // consecutive color changes don't skip numbers.
                if blockHasStitches {
                    block += 1
                    blockHasStitches = false
                }
            default:
                break
            }
        }
        self.stitches = stitches
    }

    func nearestStitch(to point: CGPoint) -> MarkupFile.StitchRef? {
        var best: Stitch?
        var bestDistance = Double.infinity
        for stitch in stitches {
            let dx = Double(stitch.x) - point.x
            let dy = Double(stitch.y) - point.y
            let distance = dx * dx + dy * dy
            if distance < bestDistance {
                bestDistance = distance
                best = stitch
            }
        }
        guard let best else { return nil }
        return MarkupFile.StitchRef(
            x: best.x,
            y: best.y,
            distanceMM: (bestDistance.squareRoot() / 10 * 10).rounded() / 10,
            stitchNumber: best.number,
            colorBlock: best.block,
            record: best.record,
            byteOffset: DSTParser.headerLength + DSTParser.recordLength * best.record
        )
    }

    func stitches(in rect: CGRect) -> MarkupFile.StitchRange {
        let inside = stitches.filter {
            CGFloat($0.x) >= rect.minX && CGFloat($0.x) <= rect.maxX &&
            CGFloat($0.y) >= rect.minY && CGFloat($0.y) <= rect.maxY
        }
        return MarkupFile.StitchRange(
            count: inside.count,
            firstStitchNumber: inside.first?.number,
            lastStitchNumber: inside.last?.number,
            firstRecord: inside.first?.record,
            lastRecord: inside.last?.record,
            colorBlocks: Array(Set(inside.map(\.block))).sorted()
        )
    }
}

// MARK: - Drawing the marks

/// Shared by the canvas and the saved picture, so what the agent sees is what was drawn.
enum MarkupDrawing {
    static let red = CGColor(srgbRed: 0.90, green: 0.16, blue: 0.16, alpha: 1)

    /// `transform` maps design units to the context; `unit` scales strokes and badges
    /// (1 for on-screen points, larger for the saved picture).
    static func draw(
        _ annotation: Annotation,
        number: Int,
        transform: CGAffineTransform,
        unit: CGFloat,
        selected: Bool,
        into context: CGContext
    ) {
        context.saveGState()
        defer { context.restoreGState() }

        let badgeCenter: CGPoint
        switch annotation.kind {
        case .pin:
            let center = annotation.point.applying(transform)
            let radius = 9 * unit
            let ring = CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2)
            if selected {
                context.setFillColor(red.copy(alpha: 0.22) ?? red)
                context.fillEllipse(in: ring)
            }
            context.setStrokeColor(CGColor(gray: 1, alpha: 0.95))
            context.setLineWidth(4.5 * unit)
            context.strokeEllipse(in: ring)
            context.setStrokeColor(red)
            context.setLineWidth((selected ? 3 : 2) * unit)
            context.strokeEllipse(in: ring)
            // Tiny crosshair: the exact point, which matters at stitch scale.
            context.setLineWidth(1 * unit)
            context.move(to: CGPoint(x: center.x - 3 * unit, y: center.y))
            context.addLine(to: CGPoint(x: center.x + 3 * unit, y: center.y))
            context.move(to: CGPoint(x: center.x, y: center.y - 3 * unit))
            context.addLine(to: CGPoint(x: center.x, y: center.y + 3 * unit))
            context.strokePath()
            badgeCenter = CGPoint(x: center.x + radius * 0.95, y: center.y + radius * 0.95)

        case .region:
            let box = annotation.rect.applying(transform).standardized
            if selected {
                context.setFillColor(red.copy(alpha: 0.10) ?? red)
                context.fill(box)
            }
            context.setStrokeColor(CGColor(gray: 1, alpha: 0.95))
            context.setLineWidth(3.5 * unit)
            context.stroke(box)
            context.setStrokeColor(red)
            context.setLineWidth((selected ? 2.5 : 1.75) * unit)
            context.setLineDash(phase: 0, lengths: [5 * unit, 3 * unit])
            context.stroke(box)
            context.setLineDash(phase: 0, lengths: [])
            badgeCenter = CGPoint(x: box.minX, y: box.maxY)      // top-left in a y-up context
        }

        let badgeRadius = 8 * unit
        context.setFillColor(red)
        context.fillEllipse(in: CGRect(x: badgeCenter.x - badgeRadius, y: badgeCenter.y - badgeRadius,
                                       width: badgeRadius * 2, height: badgeRadius * 2))
        let label = NSAttributedString(string: "\(number)", attributes: [
            .font: NSFont.systemFont(ofSize: 10 * unit, weight: .bold),
            .foregroundColor: NSColor.white
        ])
        let size = label.size()
        label.draw(at: CGPoint(x: badgeCenter.x - size.width / 2, y: badgeCenter.y - size.height / 2))
    }
}

// MARK: - The picture

/// `design.markup.png`: the whole design with every mark numbered, then a close-up of each
/// mark at stitch-level zoom with its note underneath.
enum MarkupPicture {
    static func render(design: Design, annotations: [Annotation], title: String) -> CGImage? {
        let width: CGFloat = 1600
        let margin: CGFloat = 32
        let headerHeight: CGFloat = 56
        let contentWidth = width - 2 * margin

        let mainSize = design.fittedSize(max: CGSize(width: contentWidth, height: 1000))
        let columns = min(3, max(1, annotations.count))
        let gap: CGFloat = 20
        let tileWidth = ((contentWidth - gap * CGFloat(columns - 1)) / CGFloat(columns)).rounded(.down)
        let tileHeight = (tileWidth * 0.72).rounded()
        let captionHeight: CGFloat = 50
        let rows = (annotations.count + columns - 1) / columns
        let height = margin + headerHeight + mainSize.height + 28
            + CGFloat(rows) * (tileHeight + captionHeight + gap) + margin

        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: Int(width), height: Int(height.rounded(.up)),
                                      bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }

        let previous = NSGraphicsContext.current
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
        defer { NSGraphicsContext.current = previous }

        let canvasHeight = height.rounded(.up)
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: canvasHeight))

        // Header — `top` measures down from the top edge; CG is y-up.
        var top = margin
        ReportText.draw(title, font: .systemFont(ofSize: 22, weight: .bold), color: .black,
                        topLeft: CGPoint(x: margin, y: canvasHeight - top))
        ReportText.draw(
            "\(annotations.count) annotation\(annotations.count == 1 ? "" : "s")  ·  "
                + String(format: "%.1f × %.1f mm  ·  %@ stitches", design.widthMM, design.heightMM, design.stitchCount.formatted()),
            font: .systemFont(ofSize: 13), color: .darkGray,
            topLeft: CGPoint(x: margin, y: canvasHeight - top - 30)
        )
        top += headerHeight

        // Whole design.
        let mainRect = CGRect(x: margin + (contentWidth - mainSize.width) / 2,
                              y: canvasHeight - top - mainSize.height,
                              width: mainSize.width, height: mainSize.height)
        let mainTransform = DesignRenderer.fittingTransform(for: design.bounds, in: mainSize, padding: 0.04)
        draw(design, transform: mainTransform, in: mainRect, into: context)
        let mainToCanvas = mainTransform.concatenating(CGAffineTransform(translationX: mainRect.minX, y: mainRect.minY))
        context.saveGState()
        context.clip(to: mainRect)
        for (index, annotation) in annotations.enumerated() {
            MarkupDrawing.draw(annotation, number: index + 1, transform: mainToCanvas, unit: 1.6, selected: false, into: context)
        }
        context.restoreGState()
        top += mainSize.height + 28

        // Close-ups.
        for (index, annotation) in annotations.enumerated() {
            let column = index % columns
            let row = index / columns
            let tile = CGRect(
                x: margin + CGFloat(column) * (tileWidth + gap),
                y: canvasHeight - top - CGFloat(row) * (tileHeight + captionHeight + gap) - tileHeight,
                width: tileWidth, height: tileHeight
            )
            let focus = focusRect(for: annotation)
            let transform = DesignRenderer.fittingTransform(for: focus, in: tile.size, padding: 0)
            draw(design, transform: transform, in: tile, into: context)
            context.saveGState()
            context.clip(to: tile)
            MarkupDrawing.draw(annotation, number: index + 1,
                               transform: transform.concatenating(CGAffineTransform(translationX: tile.minX, y: tile.minY)),
                               unit: 1.6, selected: false, into: context)
            context.restoreGState()

            let note = annotation.note.trimmingCharacters(in: .whitespacesAndNewlines)
            let kind = annotation.kind == .pin ? "Pin" : "Area"
            // What the tile actually shows, not the focus rect: the fit letterboxes to the tile.
            let shownWidthMM = transform.a > 0 ? tile.width / transform.a / 10 : focus.width / 10
            let scaleNote = String(format: "close-up %.0f mm wide", shownWidthMM)
            ReportText.draw("\(index + 1). \(kind) — \(scaleNote)", font: .systemFont(ofSize: 12, weight: .semibold),
                            color: .black, topLeft: CGPoint(x: tile.minX, y: tile.minY - 6), width: tileWidth)
            ReportText.draw(note.isEmpty ? "(no note)" : note, font: .systemFont(ofSize: 12), color: .darkGray,
                            topLeft: CGPoint(x: tile.minX, y: tile.minY - 24), width: tileWidth)
        }
        return context.makeImage()
    }

    /// What a close-up frames: ~15 mm around a pin, or the box with a margin around it.
    private static func focusRect(for annotation: Annotation) -> CGRect {
        switch annotation.kind {
        case .pin:
            let side: CGFloat = 150
            return CGRect(x: annotation.point.x - side / 2, y: annotation.point.y - side / 2, width: side, height: side)
        case .region:
            let r = annotation.rect
            let pad = max(20, max(r.width, r.height) * 0.25)
            return r.insetBy(dx: -pad, dy: -pad)
        }
    }

    private static func draw(_ design: Design, transform: CGAffineTransform, in rect: CGRect, into context: CGContext) {
        context.saveGState()
        context.clip(to: rect)
        context.translateBy(x: rect.minX, y: rect.minY)
        var options = DesignRenderer.Options()
        options.transform = transform
        options.drawsBackground = true
        options.drawsBorder = true
        DesignRenderer.render(design, into: context, size: rect.size, background: DesignRenderer.fabricColor, options: options)
        context.restoreGState()
    }
}
