import AppKit

struct DisplayIdentity {
    let id: CGDirectDisplayID
    let name: String
    let stableID: String
    let builtIn: Bool
    let frame: CGRect
    let vendor: UInt32
    let model: UInt32
    let edidUUID: String?
}

enum MediaAction: Int, CaseIterable {
    case volumeUp = 0, volumeDown = 1, brightnessUp = 2, brightnessDown = 3, mute = 7
    var isBrightness: Bool { self == .brightnessUp || self == .brightnessDown }
    var step: Double { isBrightness ? 1.0 / 16 : 0.01 }
    func increment(fine: Bool) -> Double { delta * step / (fine ? 4 : 1) }
    var delta: Double { self == .brightnessUp || self == .volumeUp ? 1 : -1 }
    static func decode(subtype: Int16, data1: Int) -> (MediaAction, Bool)? {
        guard subtype == 8, let action = MediaAction(rawValue: (data1 >> 16) & 0xffff) else { return nil }
        let state = (data1 >> 8) & 0xff
        guard state == 0xA || state == 0xB else { return nil }
        return (action, state == 0xA)
    }
}

enum Routing {
    // CGEvent coordinates and CGDisplayBounds both use the desktop's top-left origin.
    static func target(at point: CGPoint, displays: [DisplayIdentity]) -> DisplayIdentity? {
        displays.first { $0.frame.contains(point) }
    }
    static func stepped(_ current: Double, direction: Double, fine: Bool = false) -> Double {
        min(1, max(0, current + direction * (fine ? 1.0 / 64 : 1.0 / 16)))
    }
    static func audioMatch(displayName: String, deviceName: String) -> Bool {
        func normalize(_ s: String) -> String { s.lowercased().filter { $0.isLetter || $0.isNumber } }
        let display = normalize(displayName), device = normalize(deviceName)
        return !display.isEmpty && display == device
    }
}

func discoverDisplays() -> [DisplayIdentity] {
    NSScreen.screens.compactMap { screen in
        guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else { return nil }
        let id = number.uint32Value
        let info = TDDisplayInfo(id) as? [String: Any] ?? [:]
        let uuid = info["kCGDisplayUUID"] as? String ?? "\(CGDisplayVendorNumber(id)):\(CGDisplayModelNumber(id)):\(CGDisplaySerialNumber(id))"
        return DisplayIdentity(id: id, name: screen.localizedName, stableID: uuid,
                               builtIn: CGDisplayIsBuiltin(id) != 0, frame: CGDisplayBounds(id),
                               vendor: CGDisplayVendorNumber(id), model: CGDisplayModelNumber(id),
                               edidUUID: TDDisplayEDIDUUID(id) as String?)
    }
}

// Accumulate intent on the UI thread, including direction changes and clamping.
// The hardware worker receives only the latest absolute target for a burst.
enum ControlStep {
    static func target(current: Double, action: MediaAction, fine: Bool, unit: Double = 0) -> Double {
        let increment = action.increment(fine: fine)
        let delta = unit > 0 ? copysign(max(abs(increment), unit), increment) : increment
        let value = min(1, max(0, current + delta))
        return unit > 0 ? min(1, max(0, (value / unit).rounded() * unit)) : value
    }
}
