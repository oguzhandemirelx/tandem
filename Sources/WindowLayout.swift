import AppKit

// Scrolling exists only when measured content exceeds the bounded viewport.
struct ControlsLayout: Equatable {
    static let width: CGFloat = 340
    static let maximumHeight: CGFloat = 600
    let contentHeight: CGFloat
    let maximumHeight: CGFloat
    var height: CGFloat { min(contentHeight, maximumHeight) }
    var scrolls: Bool { contentHeight > maximumHeight }
    init(contentHeight: CGFloat, maximumHeight: CGFloat = Self.maximumHeight) {
        self.contentHeight = ceil(max(0, contentHeight))
        self.maximumHeight = max(1, min(Self.maximumHeight, floor(maximumHeight)))
    }
}

// Desktop window coordinates use a bottom-left origin.
enum WindowLayout {
    static func centered(size: CGSize, screen: CGRect) -> CGRect {
        CGRect(x: screen.midX - size.width / 2, y: screen.midY - size.height / 2, width: size.width, height: size.height)
    }
    static func availablePanelHeight(icon: CGRect, visibleScreen: CGRect) -> CGFloat {
        max(1, min(icon.minY - 6, visibleScreen.maxY - 6) - visibleScreen.minY - 8)
    }
    static func panel(size: CGSize, icon: CGRect, visibleScreen: CGRect) -> CGRect {
        let width = min(size.width, visibleScreen.width - 16)
        let height = min(size.height, visibleScreen.height - 16)
        let x = min(max(icon.midX - width / 2, visibleScreen.minX + 8), visibleScreen.maxX - width - 8)
        let top = min(icon.minY - 6, visibleScreen.maxY - 6)
        return CGRect(x: x, y: max(visibleScreen.minY + 8, top - height), width: width, height: height)
    }
}

final class ControlsPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override func cancelOperation(_ sender: Any?) { orderOut(nil) }
}

enum AppIcon {
    // Draw the Orbit mark at menu bar size.
    static func menuBar() -> NSImage {
        let image = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { _ in
            NSColor.labelColor.setStroke()
            let orbit = NSBezierPath()
            orbit.lineWidth = 1.35
            orbit.lineCapStyle = .round
            orbit.appendArc(withCenter: NSPoint(x: 9, y: 9), radius: 6.75,
                            startAngle: 36.8699, endAngle: 323.1301, clockwise: false)
            orbit.stroke()
            NSColor.labelColor.setFill()
            NSBezierPath(ovalIn: NSRect(x: 14.4, y: 7.65, width: 2.7, height: 2.7)).fill()
            return true
        }
        image.isTemplate = true
        return image
    }
}
