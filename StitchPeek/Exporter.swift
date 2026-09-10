import AppKit
import ImageIO
import StitchKit
import UniformTypeIdentifiers

/// Writes the current view out as PDF or PNG. The renderer already draws into an arbitrary
/// `CGContext`, so this is mostly the save panel.
@MainActor
enum Exporter {

    enum Format {
        case pdf
        case png

        var contentType: UTType {
            switch self {
            case .pdf: return .pdf
            case .png: return .png
            }
        }
    }

    /// PNG exports exactly what is on screen: same framing, same toggles, same stitch limit.
    /// PDF instead produces a one-page report — the whole design over its statistics — since
    /// a report of a zoomed-in crop would be no use. Both honour the viewer's toggles.
    static func export(model: ViewerModel, suggestedName: String, documentName: String, format: Format) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [format.contentType]
        panel.nameFieldStringValue = suggestedName
        panel.canCreateDirectories = true

        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            do {
                switch format {
                case .pdf: try writePDF(model: model, documentName: documentName, to: url)
                case .png: try writePNG(model: model, to: url)
                }
            } catch {
                NSAlert(error: error).runModal()
            }
        }
    }

    private enum ExportError: LocalizedError {
        case contextUnavailable
        case writeFailed

        var errorDescription: String? {
            switch self {
            case .contextUnavailable: return "Could not create a drawing context for the export."
            case .writeFailed: return "The exported file could not be written."
            }
        }
    }

    private static func exportSize(_ model: ViewerModel) -> CGSize {
        let size = model.viewSize
        guard size.width > 1, size.height > 1 else { return CGSize(width: 1000, height: 1000) }
        return size
    }

    private static func writePDF(model: ViewerModel, documentName: String, to url: URL) throws {
        var mediaBox = CGRect(origin: .zero, size: PDFReport.pageSize)
        let info: [String: Any] = [
            kCGPDFContextTitle as String: documentName,
            kCGPDFContextCreator as String: "StitchPeek"
        ]
        guard let consumer = CGDataConsumer(url: url as CFURL),
              let context = CGContext(consumer: consumer, mediaBox: &mediaBox, info as CFDictionary)
        else { throw ExportError.contextUnavailable }

        context.beginPDFPage(nil)
        PDFReport.draw(
            design: model.design,
            filename: documentName,
            options: model.renderOptions(showBackground: true),
            into: context
        )
        context.endPDFPage()
        context.closePDF()
    }

    private static func writePNG(model: ViewerModel, to url: URL) throws {
        let size = exportSize(model)
        let scale: CGFloat = 2
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(
                data: nil,
                width: Int(size.width * scale),
                height: Int(size.height * scale),
                bitsPerComponent: 8,
                bytesPerRow: 0,
                space: space,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              )
        else { throw ExportError.contextUnavailable }

        context.scaleBy(x: scale, y: scale)
        draw(model: model, into: context, size: size)

        guard let image = context.makeImage(),
              let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)
        else { throw ExportError.writeFailed }

        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw ExportError.writeFailed }
    }

    private static func draw(model: ViewerModel, into context: CGContext, size: CGSize) {
        context.setFillColor(DesignRenderer.fabricColor)
        context.fill(CGRect(origin: .zero, size: size))
        // The full design, never the decimated interaction copy.
        var options = model.renderOptions(showBackground: false)
        options.transform = model.transform
        DesignRenderer.render(model.design, into: context, size: size, background: nil, options: options)
    }
}
