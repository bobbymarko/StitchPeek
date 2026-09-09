import CoreGraphics
import Foundation
import Observation
import StitchKit

/// Canvas and inspector state for one open design.
///
/// `scale` is output points per 0.1 mm unit, so a scale of 1 is the "100%" the spec means by
/// one screen point per 0.1 mm. `center` is the design-space point sitting at the middle of
/// the view. Keeping the state in these terms makes fit, zoom-to-cursor, and the 100% command
/// all trivial.
@MainActor
@Observable
final class ViewerModel {
    let design: Design
    /// A decimated copy drawn during live pan and zoom on very large designs, so dragging
    /// stays smooth. The full design is drawn as soon as the gesture settles.
    let interactiveDesign: Design

    var scale: CGFloat = 1
    var center: CGPoint = .zero
    var viewSize: CGSize = .zero

    var showsJumps = false
    var isolatedBlockIndex: Int?
    /// Number of stitches drawn, for the scrubber. `nil` draws the whole design.
    var stitchLimit: Int?
    var isPlaying = false
    /// True while a scroll or magnify gesture is in flight.
    var isInteracting = false

    private var hasFitted = false

    /// Above this many points, live gestures draw the decimated copy.
    private static let interactiveThreshold = 60_000

    init(design: Design) {
        self.design = design
        if design.renderedPointCount > Self.interactiveThreshold {
            let longestSide = max(design.bounds.width, design.bounds.height)
            self.interactiveDesign = longestSide > 0 ? design.decimated(tolerance: longestSide / 1400) : design
        } else {
            self.interactiveDesign = design
        }
        self.center = CGPoint(x: design.bounds.midX, y: design.bounds.midY)
    }

    /// The design actually handed to the renderer this frame.
    var renderableDesign: Design {
        isInteracting ? interactiveDesign : design
    }

    // MARK: - Zoom

    var fitScale: CGFloat {
        guard viewSize.width > 0, viewSize.height > 0 else { return 1 }
        let inset = min(viewSize.width, viewSize.height) * 0.04
        let width = max(design.bounds.width, 1)
        let height = max(design.bounds.height, 1)
        return min((viewSize.width - 2 * inset) / width, (viewSize.height - 2 * inset) / height)
    }

    /// Zoom shown to the user, where 1.0 means one point per 0.1 mm.
    var zoomPercent: Int { Int((scale * 100).rounded()) }

    func fit() {
        scale = fitScale
        center = CGPoint(x: design.bounds.midX, y: design.bounds.midY)
    }

    func actualSize() {
        scale = 1
    }

    /// Fits once, the first time the canvas reports a real size.
    func fitIfNeeded(viewSize: CGSize) {
        self.viewSize = viewSize
        guard !hasFitted, viewSize.width > 0, viewSize.height > 0 else { return }
        hasFitted = true
        fit()
    }

    // MARK: - Transform

    /// Design space (0.1 mm, y-down) to view space (points, y-up).
    ///
    /// The negative `d` is the y flip. Core Graphics is y-up and the model is y-down; without
    /// this, every design renders upside down.
    var transform: CGAffineTransform {
        CGAffineTransform(
            a: scale, b: 0,
            c: 0, d: -scale,
            tx: viewSize.width / 2 - center.x * scale,
            ty: viewSize.height / 2 + center.y * scale
        )
    }

    func designPoint(at viewPoint: CGPoint) -> CGPoint {
        guard scale != 0 else { return center }
        return CGPoint(
            x: center.x + (viewPoint.x - viewSize.width / 2) / scale,
            y: center.y - (viewPoint.y - viewSize.height / 2) / scale
        )
    }

    // MARK: - Gestures

    func pan(by delta: CGSize) {
        guard scale != 0 else { return }
        center.x -= delta.width / scale
        center.y += delta.height / scale       // view y-up, design y-down
    }

    /// Multiplies the zoom while keeping `anchor` (in view coordinates) over the same stitch.
    func zoom(by factor: CGFloat, around anchor: CGPoint) {
        let anchored = designPoint(at: anchor)
        let newScale = (scale * factor).clamped(to: 0.02...80)
        guard newScale != scale else { return }
        scale = newScale
        center = CGPoint(
            x: anchored.x - (anchor.x - viewSize.width / 2) / newScale,
            y: anchored.y + (anchor.y - viewSize.height / 2) / newScale
        )
    }

    // MARK: - Inspector

    func toggleIsolation(of index: Int) {
        isolatedBlockIndex = (isolatedBlockIndex == index) ? nil : index
    }

    // MARK: - Scrubber

    var stitchesShown: Int {
        get { stitchLimit ?? design.stitchCount }
        set { stitchLimit = newValue >= design.stitchCount ? nil : max(0, newValue) }
    }

    /// ~2000 stitches per second, called from a 60 Hz timer.
    func advancePlayback(stitchesPerSecond: Double = 2000, tick: Double = 1.0 / 60.0) {
        guard isPlaying else { return }
        let next = stitchesShown + Int((stitchesPerSecond * tick).rounded())
        if next >= design.stitchCount {
            stitchLimit = nil
            isPlaying = false
        } else {
            stitchLimit = next
        }
    }

    func togglePlayback() {
        if isPlaying {
            isPlaying = false
        } else {
            // Restarting from the end replays from the beginning.
            if stitchLimit == nil { stitchLimit = 0 }
            isPlaying = true
        }
    }

    // MARK: - Render options

    func renderOptions(showBackground: Bool = true) -> DesignRenderer.Options {
        var options = DesignRenderer.Options()
        options.transform = transform
        options.showsJumps = showsJumps
        options.isolatedBlockIndex = isolatedBlockIndex
        options.maxStitch = stitchLimit
        options.drawsBackground = showBackground
        options.drawsBorder = false
        return options
    }
}

private extension Comparable {
    func clamped(to range: ClosedRange<Self>) -> Self {
        min(max(self, range.lowerBound), range.upperBound)
    }
}
