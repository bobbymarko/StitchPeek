import AppKit
import CoreGraphics

/// Text drawing and number formatting shared by the PDF report and the contact sheet.
/// Both draw into y-up Core Graphics contexts through `NSGraphicsContext`.
enum ReportText {

    /// Draws one line and returns the height it consumed, so callers can walk down a page
    /// without tracking font metrics themselves. `topLeft` is the top of the line.
    @discardableResult
    static func draw(_ string: String, font: NSFont, color: NSColor, topLeft: CGPoint) -> CGFloat {
        let attributed = NSAttributedString(string: string, attributes: [.font: font, .foregroundColor: color])
        let size = attributed.size()
        attributed.draw(at: CGPoint(x: topLeft.x, y: topLeft.y - size.height))
        return size.height
    }

    /// Draws one line clipped to `width`, truncating with an ellipsis. Returns the height.
    @discardableResult
    static func draw(_ string: String, font: NSFont, color: NSColor, topLeft: CGPoint, width: CGFloat) -> CGFloat {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byTruncatingTail
        let attributed = NSAttributedString(
            string: string,
            attributes: [.font: font, .foregroundColor: color, .paragraphStyle: paragraph]
        )
        let height = attributed.size().height
        attributed.draw(
            with: CGRect(x: topLeft.x, y: topLeft.y - height, width: width, height: height),
            options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine]
        )
        return height
    }
}

enum ReportFormat {
    /// Metres for real designs, smaller units for short blocks — "~0.0 m" tells nobody anything.
    static func length(mm: Double) -> String {
        if mm >= 1000 { return String(format: "~%.1f m", mm / 1000) }
        if mm >= 10 { return String(format: "~%.0f cm", mm / 10) }
        return String(format: "~%.0f mm", mm)
    }

    static func duration(_ seconds: TimeInterval) -> String {
        let minutes = Int((seconds / 60).rounded())
        if minutes < 60 { return "~\(max(minutes, 1)) min" }
        let hours = minutes / 60
        let remainder = minutes % 60
        return remainder == 0 ? "~\(hours) h" : "~\(hours) h \(remainder) min"
    }

    static func dimensions(widthInches: Double, heightInches: Double, widthMM: Double, heightMM: Double) -> String {
        String(format: "%.2f × %.2f in  (%.0f × %.0f mm)", widthInches, heightInches, widthMM, heightMM)
    }
}
