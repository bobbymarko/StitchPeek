import AppKit
import StitchKit
import SwiftUI

/// The stitch canvas.
///
/// AppKit rather than SwiftUI's `Canvas`: at 200k stitches `Canvas` cannot keep up, while a
/// plain `NSView` stroking one `CGPath` per color block redraws in a few milliseconds.
struct DesignCanvasView: NSViewRepresentable {
    let model: ViewerModel

    func makeNSView(context: Context) -> DesignCanvasNSView {
        let view = DesignCanvasNSView()
        view.model = model
        return view
    }

    func updateNSView(_ view: DesignCanvasNSView, context: Context) {
        view.model = model
        view.needsDisplay = true
    }
}

final class DesignCanvasNSView: NSView {
    var model: ViewerModel?

    /// Core Graphics' own y-up orientation. The model is y-down and the fitting transform
    /// inverts y; flipping the view as well would cancel that out and stand every design
    /// back on its head.
    override var isFlipped: Bool { false }

    override var acceptsFirstResponder: Bool { true }

    private var settleTask: Task<Void, Never>?

    // MARK: - Drawing

    override func draw(_ dirtyRect: NSRect) {
        guard let model,
              let context = NSGraphicsContext.current?.cgContext
        else { return }

        model.fitIfNeeded(viewSize: bounds.size)

        context.setFillColor(DesignRenderer.fabricColor)
        context.fill(bounds)

        DesignRenderer.render(
            model.renderableDesign,
            into: context,
            size: bounds.size,
            background: nil,
            options: model.renderOptions(showBackground: false)
        )
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        model?.viewSize = newSize
        needsDisplay = true
    }

    // MARK: - Pan and zoom

    override func scrollWheel(with event: NSEvent) {
        guard let model else { return }
        beginInteraction()

        if event.modifierFlags.contains(.command) {
            // Command-scroll zooms, matching the usual macOS convention.
            let factor = 1 + event.scrollingDeltaY * 0.01
            model.zoom(by: factor, around: convert(event.locationInWindow, from: nil))
        } else {
            var delta = CGSize(width: event.scrollingDeltaX, height: event.scrollingDeltaY)
            if !event.hasPreciseScrollingDeltas {
                delta.width *= 8
                delta.height *= 8
            }
            // A trackpad scrolls content, so dragging down moves the design up.
            model.pan(by: CGSize(width: delta.width, height: -delta.height))
        }
        needsDisplay = true
    }

    override func magnify(with event: NSEvent) {
        guard let model else { return }
        beginInteraction()
        model.zoom(by: 1 + event.magnification, around: convert(event.locationInWindow, from: nil))
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        guard let model else { return }
        beginInteraction()
        model.pan(by: CGSize(width: event.deltaX, height: event.deltaY))
        needsDisplay = true
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
    }

    /// Draws the decimated copy while a gesture is running, then the full design once it
    /// settles. Debounced rather than driven off `NSEvent.phase`, which momentum scrolling
    /// and the Magic Mouse report inconsistently.
    private func beginInteraction() {
        model?.isInteracting = true
        settleTask?.cancel()
        settleTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(120))
            guard !Task.isCancelled, let self else { return }
            self.model?.isInteracting = false
            self.needsDisplay = true
        }
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .openHand)
    }
}
