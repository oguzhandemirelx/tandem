import AppKit

// A level meter, not a task-progress control: paint the requested fraction on
// the same display pass as the percentage, without AppKit progress animation.
final class HUDLevelBar: NSView {
    private(set) var value: Double = 0
    func setLevel(_ level: Double) {
        value = min(1, max(0, level))
        setAccessibilityValue("\(Int((value * 100).rounded()))%")
        needsDisplay = true
    }
    override func draw(_ dirtyRect: NSRect) {
        let radius = bounds.height / 2
        NSColor.labelColor.withAlphaComponent(0.18).setFill()
        NSBezierPath(roundedRect: bounds, xRadius: radius, yRadius: radius).fill()
        let fill = NSRect(x: bounds.minX, y: bounds.minY, width: bounds.width * value, height: bounds.height)
        guard fill.width > 0 else { return }
        NSColor.labelColor.setFill()
        NSBezierPath(roundedRect: fill, xRadius: min(radius, fill.width / 2), yRadius: radius).fill()
    }
}

final class HUD {
    private var panel: NSPanel?
    private var hide: DispatchWorkItem?
    private var generation = 0
    private let title = NSTextField(labelWithString: "")
    private let icon = NSImageView()
    private let progress = HUDLevelBar()
    private let percentage = NSTextField(labelWithString: "")
    private let message = NSTextField(wrappingLabelWithString: "")

    func show(display: DisplayIdentity, action: MediaAction, value: Double?, error: String? = nil, title titleOverride: String? = nil) {
        guard let screen = NSScreen.screens.first(where: {
            ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == display.id
        }) else { return }
        hide?.cancel()
        generation += 1
        let currentGeneration = generation
        let width: CGFloat = error == nil ? 280 : 420, height: CGFloat = error == nil ? 110 : 130
        let frame = NSRect(x: screen.frame.midX - width / 2, y: screen.visibleFrame.minY + 75, width: width, height: height)
        let window: NSPanel
        if let existing = panel { window = existing }
        else {
            window = NSPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            window.identifier = NSUserInterfaceItemIdentifier("TandemHUD")
            window.level = .floating; window.isOpaque = false; window.backgroundColor = .clear
            window.isReleasedWhenClosed = false; window.ignoresMouseEvents = true
            window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            let effect = NSVisualEffectView()
            effect.material = .hudWindow; effect.blendingMode = .behindWindow; effect.state = .active
            effect.wantsLayer = true; effect.layer?.cornerRadius = 18; effect.layer?.masksToBounds = true
            title.font = .systemFont(ofSize: 12, weight: .medium); title.textColor = .secondaryLabelColor
            title.alignment = .center
            progress.identifier = NSUserInterfaceItemIdentifier("HUDLevelBar")
            progress.setAccessibilityElement(true)
            progress.setAccessibilityRole(.progressIndicator)
            percentage.font = .monospacedDigitSystemFont(ofSize: 15, weight: .medium)
            percentage.identifier = NSUserInterfaceItemIdentifier("HUDPercent")
            message.font = .systemFont(ofSize: 13)
            for view in [title, icon, progress, percentage, message] { effect.addSubview(view) }
            window.contentView = effect
            panel = window
        }
        // Keep the panel and its content mounted throughout a key-repeat burst.
        // Updating an existing value must not order the window out and back in.
        if window.frame != frame { window.setFrame(frame, display: true) }
        title.stringValue = titleOverride ?? display.name
        title.frame = NSRect(x: 20, y: height - 28, width: width - 40, height: 18)
        let symbol = action.isBrightness ? "sun.max.fill" : ((value ?? 0) == 0 ? "speaker.slash.fill" : "speaker.wave.2.fill")
        icon.image = NSImage(systemSymbolName: error == nil ? symbol : "exclamationmark.triangle", accessibilityDescription: nil)
        icon.contentTintColor = error == nil ? .labelColor : .systemOrange
        icon.frame = NSRect(x: 22, y: 32, width: 26, height: 26)
        progress.frame = NSRect(x: 62, y: 42, width: 142, height: 8)
        progress.setAccessibilityLabel(action.isBrightness ? "Brightness" : "Volume")
        progress.setLevel(value ?? 0)
        percentage.stringValue = "\(Int(((value ?? 0) * 100).rounded()))%"
        percentage.frame = NSRect(x: 218, y: 35, width: 50, height: 24)
        message.stringValue = error ?? ""
        message.frame = NSRect(x: 60, y: 20, width: width - 80, height: 64)
        progress.isHidden = error != nil; percentage.isHidden = error != nil; message.isHidden = error == nil
        if !window.isVisible { window.orderFrontRegardless() }
        // Flush the text and the bar together, even during fast key repeats.
        window.displayIfNeeded()
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.generation == currentGeneration else { return }
            self.panel?.orderOut(nil)
        }
        hide = work
        DispatchQueue.main.asyncAfter(deadline: .now() + (error == nil ? 1.2 : 3), execute: work)
    }
}
