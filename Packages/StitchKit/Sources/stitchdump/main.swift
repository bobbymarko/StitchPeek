import CoreGraphics
import Foundation
import ImageIO
import StitchKit
import UniformTypeIdentifiers

/// Diagnostic CLI. Two modes:
///
///     stitchdump records <file.dst>   canonical "x,y,command" lines — diff this against
///                                     Scripts/reference_decoder.py over any corpus
///     stitchdump stats   <file.dst>   parsed summary
///     stitchdump png     <file.dst> <out.png> [size]   render through DesignRenderer
///
/// Exists so the parser can be checked against the Python reference on real files that are
/// too private, or too large, to commit as fixtures.

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(2)
}

let arguments = Array(CommandLine.arguments.dropFirst())
guard arguments.count >= 2 else {
    fail("usage: stitchdump <records|stats> <file.dst>")
}

let mode = arguments[0]
let url = URL(fileURLWithPath: arguments[1])

switch mode {
case "records":
    guard let data = try? Data(contentsOf: url) else { fail("cannot read \(url.path)") }
    var out = ""
    out.reserveCapacity(1 << 20)
    for record in DSTParser.decodeRecords(data: data) {
        out += "\(record.x),\(record.y),\(record.command)\n"
    }
    FileHandle.standardOutput.write(Data(out.utf8))

case "stats":
    do {
        let design = try DSTParser.parse(contentsOf: url)
        let header = design.header
        print("file           \(url.lastPathComponent)")
        print("name           \(design.name ?? "-")")
        print("stitches       \(design.stitchCount)")
        print("jumps          \(design.jumpCount)")
        print("trims (est.)   \(design.trimCount)")
        print("color changes  \(design.colorChangeCount)")
        print("blocks         \(design.blocks.count)")
        print("truncated      \(design.isTruncated)")
        print("invalid recs   \(design.invalidRecordCount)")
        print(String(format: "size           %.1f x %.1f mm  (%.2f x %.2f in)",
                     design.widthMM, design.heightMM, design.widthInches, design.heightInches))
        print("bounds         x \(Int(design.bounds.minX))…\(Int(design.bounds.maxX))  y \(Int(design.bounds.minY))…\(Int(design.bounds.maxY))")
        if let header {
            print("header ST/CO   \(header.recordCount.map(String.init) ?? "-") / \(header.colorChanges.map(String.init) ?? "-")")
            print("header extent  +X \(header.plusX.map(String.init) ?? "-")  -X \(header.minusX.map(String.init) ?? "-")  +Y \(header.plusY.map(String.init) ?? "-")  -Y \(header.minusY.map(String.init) ?? "-")")
            // The header is only ever a sanity check; geometry comes from the stitches.
            if let plusX = header.plusX, let minusX = header.minusX,
               let plusY = header.plusY, let minusY = header.minusY {
                let deltas = [
                    abs(Int(design.bounds.maxX) - plusX),
                    abs(Int(design.bounds.minX) + minusX),
                    abs(Int(design.bounds.maxY) - plusY),
                    abs(Int(design.bounds.minY) + minusY)
                ]
                print("header agrees  \(deltas.allSatisfy { $0 <= 1 } ? "yes" : "NO  deltas \(deltas)")")
            }
        } else {
            print("header         (unreadable)")
        }
    } catch {
        fail("parse failed: \(error.localizedDescription)")
    }

case "png":
    guard arguments.count >= 3 else { fail("usage: stitchdump png <file.dst> <out.png> [size]") }
    let side = arguments.count >= 4 ? (Double(arguments[3]) ?? 900) : 900
    do {
        let design = try DSTParser.parse(contentsOf: url)
        let size = design.fittedSize(max: CGSize(width: side, height: side))
        guard let image = DesignRenderer.image(design, size: size, scale: 2) else { fail("render failed") }
        let out = URL(fileURLWithPath: arguments[2])
        guard let destination = CGImageDestinationCreateWithURL(out as CFURL, UTType.png.identifier as CFString, 1, nil) else {
            fail("cannot write \(out.path)")
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { fail("cannot finalize \(out.path)") }
        print("wrote \(out.path)  \(Int(size.width))x\(Int(size.height)) @2x")
    } catch {
        fail("parse failed: \(error.localizedDescription)")
    }

default:
    fail("unknown mode '\(mode)'")
}
