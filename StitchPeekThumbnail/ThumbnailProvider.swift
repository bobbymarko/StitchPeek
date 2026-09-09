import CoreGraphics
import OSLog
import QuickLookThumbnailing
import StitchKit

/// Finder thumbnails for `.dst`.
///
/// Parses decimated: above 50k stitches, points closer together than one output pixel are
/// dropped. At icon sizes it is invisible, and it keeps the work well inside the budget
/// Quick Look allows before it kills the extension.
final class ThumbnailProvider: QLThumbnailProvider {

    private static let log = Logger(subsystem: "com.bobbymarko.stitchpeek", category: "thumbnail")

    override func provideThumbnail(
        for request: QLFileThumbnailRequest,
        _ handler: @escaping (QLThumbnailReply?, Error?) -> Void
    ) {
        do {
            let design = try DSTParser.parse(contentsOf: request.fileURL, decimated: true)

            // Keep the design's aspect ratio rather than filling a square with dead fabric.
            let contextSize = design.fittedSize(max: request.maximumSize)

            handler(
                QLThumbnailReply(contextSize: contextSize) { context in
                    DesignRenderer.render(
                        design,
                        into: context,
                        size: contextSize,
                        background: DesignRenderer.fabricColor
                    )
                    return true
                },
                nil
            )
        } catch {
            Self.log.error("could not parse \(request.fileURL.lastPathComponent, privacy: .public): \(error.localizedDescription, privacy: .public)")
            // Reporting the error lets Finder fall back to the generic document icon.
            handler(nil, error)
        }
    }
}
