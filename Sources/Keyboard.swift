import AppKit

final class KeyboardListener {
    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    var onAction: ((MediaAction, CGPoint, Bool) -> Bool)?
    var onStatus: ((Bool) -> Void)?
    private var consumed: Set<MediaAction> = []
    var active: Bool { tap.map { CGEvent.tapIsEnabled(tap: $0) } ?? false }
    func start() -> Bool {
        if active { return true }
        stop()
        guard AXIsProcessTrusted() else { return false }
        let mask = CGEventMask(1) << CGEventType(rawValue: 14)!.rawValue
        guard let created = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
            eventsOfInterest: mask, callback: { _, type, event, context in
                guard let context else { return Unmanaged.passUnretained(event) }
                let listener = Unmanaged<KeyboardListener>.fromOpaque(context).takeUnretainedValue()
                if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                    if let tap = listener.tap { CGEvent.tapEnable(tap: tap, enable: true) }
                    listener.onStatus?(listener.active)
                    return Unmanaged.passUnretained(event)
                }
                guard let nsEvent = NSEvent(cgEvent: event),
                      let (action, down) = MediaAction.decode(subtype: nsEvent.subtype.rawValue, data1: nsEvent.data1) else {
                    return Unmanaged.passUnretained(event)
                }
                if !down {
                    if listener.consumed.remove(action) != nil { return nil }
                    return Unmanaged.passUnretained(event)
                }
                // Holding mute must not toggle it repeatedly.
                if action == .mute && nsEvent.data1 & 1 != 0 { return nil }
                // Read the pointer at the key event, not the foreground window or main display.
                let mouse = NSEvent.mouseLocation
                let height = NSScreen.screens.first?.frame.maxY ?? CGDisplayBounds(CGMainDisplayID()).height
                let point = CGPoint(x: mouse.x, y: height - mouse.y)
                let fine = nsEvent.modifierFlags.contains(.option) && nsEvent.modifierFlags.contains(.shift)
                if listener.onAction?(action, point, fine) == true {
                    listener.consumed.insert(action)
                    return nil
                }
                return Unmanaged.passUnretained(event)
            }, userInfo: Unmanaged.passUnretained(self).toOpaque()) else { return false }
        tap = created
        source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, created, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: created, enable: true)
        onStatus?(true)
        return true
    }
    func stop() {
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        if let tap { CGEvent.tapEnable(tap: tap, enable: false); CFMachPortInvalidate(tap) }
        tap = nil; source = nil; consumed.removeAll()
    }
    deinit { stop() }
}
