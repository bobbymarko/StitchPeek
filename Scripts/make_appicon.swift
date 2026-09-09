// Builds StitchPeek/Assets.xcassets/AppIcon.appiconset from Design/AppIcon-source.png.
//
//     swift Scripts/make_appicon.swift
//
// The source is full-bleed square art. macOS app icons are not: they sit in a rounded
// superellipse inset from the canvas edge, so an unmasked square reads as oversized and
// foreign next to every other icon in the Dock. Apple's reference geometry on a 1024 canvas
// is an 824-point body with a 185.4-point corner radius, which is what the ratios below are.

import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

let bodyRatio: CGFloat = 824.0 / 1024.0
let cornerRatio: CGFloat = 185.4 / 824.0

/// (point size, scale) pairs macOS asks for.
let variants: [(Int, Int)] = [
    (16, 1), (16, 2),
    (32, 1), (32, 2),
    (128, 1), (128, 2),
    (256, 1), (256, 2),
    (512, 1), (512, 2)
]

let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let source = root.appendingPathComponent("Design/AppIcon-source.png")
let outputDirectory = root.appendingPathComponent("StitchPeek/Assets.xcassets/AppIcon.appiconset")

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(1)
}

guard let imageSource = CGImageSourceCreateWithURL(source as CFURL, nil),
      let artwork = CGImageSourceCreateImageAtIndex(imageSource, 0, nil)
else { fail("could not read \(source.path)") }

try? FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)

func writeIcon(pixels: Int, to url: URL) {
    guard let space = CGColorSpace(name: CGColorSpace.sRGB),
          let context = CGContext(
            data: nil,
            width: pixels,
            height: pixels,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: space,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
          )
    else { fail("could not create a \(pixels)px context") }

    context.interpolationQuality = .high

    let canvas = CGFloat(pixels)
    let body = (canvas * bodyRatio).rounded()
    let origin = ((canvas - body) / 2).rounded()
    let rect = CGRect(x: origin, y: origin, width: body, height: body)
    let radius = body * cornerRatio

    let path = CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)
    context.addPath(path)
    context.clip()
    context.draw(artwork, in: rect)

    guard let image = context.makeImage(),
          let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)
    else { fail("could not encode \(url.lastPathComponent)") }
    CGImageDestinationAddImage(destination, image, nil)
    guard CGImageDestinationFinalize(destination) else { fail("could not write \(url.lastPathComponent)") }
}

var entries: [String] = []
for (points, scale) in variants {
    let pixels = points * scale
    let name = "icon_\(points)x\(points)\(scale == 2 ? "@2x" : "").png"
    writeIcon(pixels: pixels, to: outputDirectory.appendingPathComponent(name))
    entries.append("""
        {
          "filename" : "\(name)",
          "idiom" : "mac",
          "scale" : "\(scale)x",
          "size" : "\(points)x\(points)"
        }
    """)
    print("wrote \(name)  \(pixels)x\(pixels)")
}

let contents = """
{
  "images" : [
\(entries.joined(separator: ",\n"))
  ],
  "info" : {
    "author" : "xcode",
    "version" : 1
  }
}

"""
try? contents.write(to: outputDirectory.appendingPathComponent("Contents.json"), atomically: true, encoding: .utf8)
print("wrote Contents.json")
