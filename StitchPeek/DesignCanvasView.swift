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
        // Read here so SwiftUI redraws the canvas when the marks or the mode change.
        _ = model.annotations
        _ = model.selectedAnnotationID
        if view.isMarkingUp != model.isMarkingUp {
            view.isMarkingUp = model.isMarkingUp
            view.window?.invalidateCursorRects(for: view)
        }
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

    /// Mirrors the model, so cursor rects know which cursor to show.
    var isMarkingUp = false
    /// An area being dragged out in markup mode, in view coordinates.
    private var dragStart: CGPoint?
    private var dragCurrent: CGPoint?
    /// Below this a drag counts as a click, so a slightly shaky click still drops a pin.
    private static let dragThreshold: CGFloat = 5

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

        let transform = model.transform
        for (index, annotation) in model.annotations.enumerated() {
            MarkupDrawing.draw(annotation, number: index + 1, transform: transform, unit: 1,
                               selected: annotation.id == model.selectedAnnotationID, into: context)
        }

        if let start = dragStart, let current = dragCurrent {
            let box = CGRect(x: min(start.x, current.x), y: min(start.y, current.y),
                             width: abs(current.x - start.x), height: abs(current.y - start.y))
            context.setFillColor(MarkupDrawing.red.copy(alpha: 0.08) ?? MarkupDrawing.red)
            context.fill(box)
            context.setStrokeColor(MarkupDrawing.red)
            context.setLineWidth(1.5)
            context.setLineDash(phase: 0, lengths: [5, 3])
            context.stroke(box)
            context.setLineDash(phase: 0, lengths: [])
        }
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
        if model.isMarkingUp, dragStart != nil {
            dragCurrent = convert(event.locationInWindow, from: nil)
            needsDisplay = true
            return
        }
        beginInteraction()
        model.pan(by: CGSize(width: event.deltaX, height: event.deltaY))
        needsDisplay = true
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        guard let model, model.isMarkingUp else { return }
        dragStart = convert(event.locationInWindow, from: nil)
        dragCurrent = nil
    }

    /// In markup mode: a click selects the mark under it or drops a pin; a drag boxes an area.
    override func mouseUp(with event: NSEvent) {
        guard let model, model.isMarkingUp, let start = dragStart else { return }
        let end = dragCurrent ?? start
        dragStart = nil
        dragCurrent = nil

        if hypot(end.x - start.x, end.y - start.y) >= Self.dragThreshold {
            let a = model.designPoint(at: start)
            let b = model.designPoint(at: end)
            let rect = CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(b.x - a.x), height: abs(b.y - a.y))
            model.addAnnotation(.region(rect))
        } else if let existing = model.annotation(atView: start) {
            model.selectedAnnotationID = existing.id
        } else {
            model.addAnnotation(.pin(at: model.designPoint(at: start)))
        }
        needsDisplay = true
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
        addCursorRect(bounds, cursor: isMarkingUp ? .crosshair : .openHand)
    }
}
