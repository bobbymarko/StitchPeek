import CoreGraphics
import OSLog
// QuickLookUI, not QuickLook: on macOS that is where QLPreviewProvider, QLPreviewReply and
// QLPreviewingController live. `import QuickLook` is the iOS spelling and fails here with
// "cannot find type in scope".
import QuickLookUI
import StitchKit

/// Data-based Quick Look preview.
///
/// Deliberately not the view-based `QLPreviewingController` + storyboard route: this is less
/// code, and the reply is vector, so it scales cleanly at any preview size.
///
/// Nothing here may trap. A Quick Look extension that crashes gets throttled and then
/// silently disabled by the system, which looks exactly like a registration problem.
final class PreviewProvider: QLPreviewProvider, QLPreviewingController {

    /// Longest edge of the vector context. The reply keeps the design's aspect ratio.
    private static let maximumEdge: CGFloat = 1000

    private static let log = Logger(subsystem: "com.bobbymarko.stitchpeek", category: "preview")

    func providePreview(for request: QLFilePreviewRequest) async throws -> QLPreviewReply {
        let design: Design
        do {
            design = try DSTParser.parse(contentsOf: request.fileURL)
        } catch {
            Self.log.error("could not parse \(request.fileURL.lastPathComponent, privacy: .public): \(error.localizedDescription, privacy: .public)")
            throw error
        }

        let contextSize = design.fittedSize(
            max: CGSize(width: Self.maximumEdge, height: Self.maximumEdge)
        )

        // `design` is Sendable, which is why the model carries `StitchColor` rather than
        // `NSColor` — it has to cross into this @Sendable block under Swift 6.
        // The block's ObjC signature is (CGContext, QLPreviewReply, NSError**) -> BOOL, which
        // Swift imports as a throwing two-argument closure labelled `drawUsing:`.
        return QLPreviewReply(
            contextSize: contextSize,
            isBitmap: false,
            drawUsing: { context, _ in
                DesignRenderer.render(
                    design,
                    into: context,
                    size: contextSize,
                    background: DesignRenderer.fabricColor
                )
            }
        )
    }
}
