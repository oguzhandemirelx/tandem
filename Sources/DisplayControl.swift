import Foundation

final class MonitorControl {
    let identity: DisplayIdentity
    private var transport: OpaquePointer?
    private(set) var capabilities: DDCCapabilities?
    private(set) var brightness: Double?
    private(set) var volume: Double?
    private var brightnessMaximum: UInt16 = 100
    private var volumeMaximum: UInt16 = 100
    private var beforeMute: Double?
    var brightnessUnit: Double { identity.builtIn ? 0 : 1 / Double(brightnessMaximum) }
    var volumeUnit: Double { hardwareVolume ? 1 / Double(volumeMaximum) : 0 }
    var ddcChip: UInt32 { TDTransportChip(transport) }
    var hardwareBrightness: Bool { brightness != nil }
    var hardwareVolume: Bool { volume != nil }

    init(_ identity: DisplayIdentity) {
        self.identity = identity
        if identity.builtIn {
            var value: Float = 0
            if TDBrightnessGet(identity.id, &value) == 0 { brightness = Double(value) }
        } else {
            transport = TDOpenTransport(identity.id)
            var buffer = [CChar](repeating: 0, count: 4096)
            if TDReadCapabilities(transport, &buffer, UInt32(buffer.count)) == 0 {
                capabilities = DDCCapabilities(String(cString: buffer))
            }
            // Capability advertisements can be incomplete. Confirm the two controls
            // we actually offer with valid Get VCP replies, including their maxima.
            if let value = readVCP(0x10) { brightness = value.0; brightnessMaximum = value.1 }
            if let value = readVCP(0x62) { volume = value.0; volumeMaximum = value.1 }
        }
    }
    deinit { TDCloseTransport(transport) }
    func readVCP(_ code: UInt8) -> (Double, UInt16)? {
        var current: UInt16 = 0, maximum: UInt16 = 0
        guard TDReadVCP(transport, code, &current, &maximum) == 0, maximum > 0 else { return nil }
        return (Double(current) / Double(maximum), maximum)
    }
    func currentBrightness() -> Double? {
        if identity.builtIn {
            var value: Float = 0
            guard TDBrightnessGet(identity.id, &value) == 0 else { return nil }
            brightness = Double(value)
        } else {
            guard let value = readVCP(0x10) else { return nil }
            brightness = value.0
            brightnessMaximum = value.1
        }
        return brightness
    }
    func currentVolume() -> Double? {
        guard let value = readVCP(0x62) else { return nil }
        volume = value.0
        volumeMaximum = value.1
        return volume
    }
    func setBrightness(_ value: Double) throws {
        let target = min(1, max(0, value))
        let result = identity.builtIn ? TDBrightnessSet(identity.id, Float(target))
            : TDWriteVCP(transport, 0x10, UInt16((target * Double(brightnessMaximum)).rounded()))
        guard result == 0 else { throw ControlError.failed("Couldn’t adjust brightness (\(result)).") }
        brightness = target
    }
    func volumeTarget(current: Double, adjustment: Double) -> Double {
        // DDC volume is integer-valued. A fine key press must move at least one hardware unit.
        let delta = adjustment == 0 ? 0 : copysign(max(abs(adjustment), 1 / Double(volumeMaximum)), adjustment)
        return min(1, max(0, current + delta))
    }
    func setVolume(_ value: Double) throws {
        guard hardwareVolume else { throw ControlError.failed("This monitor doesn’t support DDC volume control.") }
        let target = min(1, max(0, value))
        let result = TDWriteVCP(transport, 0x62, UInt16((target * Double(volumeMaximum)).rounded()))
        guard result == 0 else { throw ControlError.failed("Couldn’t adjust monitor volume (\(result)).") }
        volume = target
    }
    func toggleMute() throws -> Double {
        guard let current = currentVolume() else { throw ControlError.failed("Couldn’t read monitor volume.") }
        let target: Double
        if current > 0 { beforeMute = current; target = 0 }
        else { target = beforeMute ?? 0.25; beforeMute = nil }
        try setVolume(target)
        return target
    }
}

// All hardware calls share one serial queue; event taps never wait on DDC.
final class ControlCoordinator {
    let queue = DispatchQueue(label: "com.oguzhandemirelx.Tandem.hardware")
    let audio: AudioHardware
    init(audio: AudioHardware = AudioController()) { self.audio = audio }
    private var monitors: [CGDirectDisplayID: MonitorControl] = [:]
    private var priorVolumes: [String: Double] = [:]
    private struct Request {
        var action: MediaAction
        let display: DisplayIdentity
        var adjustment: Double
        var absolute: Double? = nil
        var outputID: UInt32? = nil
        var completion: (Result<Double, Error>) -> Void
    }
    private let pendingLock = NSLock()
    private var pending: [Request] = []
    private var draining = false
    struct Capability {
        let id: CGDirectDisplayID
        let brightness: Bool
        let ddcVolume: Bool
        let device: AudioDevice?
        let chip: UInt32
        let brightnessUnit: Double
        let volumeUnit: Double
    }
    func refresh(_ identities: [DisplayIdentity], completion: @escaping ([Capability], [AudioDevice]) -> Void) {
        queue.async {
            self.monitors = Dictionary(uniqueKeysWithValues: identities.map { ($0.id, MonitorControl($0)) })
            let devices = self.audio.devices()
            let capabilities = identities.map { identity in
                let monitor = self.monitors[identity.id]!
                return Capability(id: identity.id, brightness: monitor.hardwareBrightness, ddcVolume: monitor.hardwareVolume,
                                  device: self.audio.matched(identity, devices: devices), chip: monitor.ddcChip,
                                  brightnessUnit: monitor.brightnessUnit, volumeUnit: monitor.volumeUnit)
            }
            DispatchQueue.main.async { completion(capabilities, devices) }
        }
    }
    struct Levels {
        let id: CGDirectDisplayID
        let stableID: String
        let brightness: Double?
        let volume: Double?
        let muted: Bool
    }
    struct Output {
        let device: AudioDevice
        let volume: Double?
        let muted: Bool
    }
    func readOutput(completion: @escaping (Output?) -> Void) {
        queue.async {
            let devices = self.audio.devices()
            let active = devices.first { $0.id == self.audio.defaultOutput() }
            let independent = AudioRouting.independentOutput(active: active, displays: self.monitors.values.map(\.identity), devices: devices)
            let output = independent.map { Output(device: $0, volume: self.audio.volume($0.id), muted: self.audio.muted($0.id) ?? false) }
            DispatchQueue.main.async { completion(output) }
        }
    }
    func readLevels(completion: @escaping ([Levels]) -> Void) {
        queue.async {
            let devices = self.audio.devices()
            let levels = self.monitors.values.map { monitor -> Levels in
                let identity = monitor.identity
                let device = self.audio.matched(identity, devices: devices)
                let ddc = !identity.builtIn && monitor.hardwareVolume
                let volume = ddc ? monitor.currentVolume() : device.flatMap { self.audio.volume($0.id) }
                let muted = ddc ? volume == 0 : device.flatMap { self.audio.muted($0.id) } ?? (volume == 0)
                return Levels(id: identity.id, stableID: identity.stableID, brightness: monitor.currentBrightness(), volume: volume, muted: muted)
            }
            DispatchQueue.main.async { completion(levels) }
        }
    }
    func perform(_ action: MediaAction, display: DisplayIdentity, fine: Bool, completion: @escaping (Result<Double, Error>) -> Void) {
        let request = Request(action: action, display: display, adjustment: action.increment(fine: fine), completion: completion)
        enqueue(request)
    }
    func setLevel(_ value: Double, brightness: Bool, display: DisplayIdentity, completion: @escaping (Result<Double, Error>) -> Void) {
        enqueue(Request(action: brightness ? .brightnessUp : .volumeUp, display: display, adjustment: 0,
                        absolute: min(1, max(0, value)), completion: completion))
    }
    private func enqueue(_ request: Request) {
        var request = request
        if !request.action.isBrightness { request.outputID = audio.defaultOutput() }
        pendingLock.lock()
        if let last = pending.last, last.display.stableID == request.display.stableID, request.action != .mute,
           last.action == request.action, last.outputID == request.outputID, (last.absolute == nil) == (request.absolute == nil) {
            if request.absolute != nil { pending[pending.count - 1].absolute = request.absolute }
            else { pending[pending.count - 1].adjustment += request.adjustment }
            pending[pending.count - 1].completion = request.completion
        } else { pending.append(request) }
        let shouldStart = !draining
        draining = true
        pendingLock.unlock()
        if shouldStart { queue.async { self.processNext() } }
    }
    private func processNext() {
        pendingLock.lock()
        guard !pending.isEmpty else { draining = false; pendingLock.unlock(); return }
        let request = pending.removeFirst()
        pendingLock.unlock()
        let result = Result { try execute(request) }
        DispatchQueue.main.async { request.completion(result) }
        // Yield between writes so display reconnects and wake refreshes can run.
        queue.async { self.processNext() }
    }
    private func monitor(for display: DisplayIdentity) throws -> MonitorControl {
        guard let monitor = monitors[display.id], monitor.identity.stableID == display.stableID else {
            throw ControlError.failed("The display connection changed. Try again.")
        }
        return monitor
    }
    private func execute(_ request: Request) throws -> Double {
        if request.action.isBrightness {
            let monitor = try monitor(for: request.display)
            guard let current = request.absolute != nil ? monitor.brightness : monitor.currentBrightness() else {
                throw ControlError.failed("Brightness control isn’t supported for this display.")
            }
            let target = request.absolute ?? min(1, max(0, current + request.adjustment))
            try monitor.setBrightness(target)
            return target
        }

        // Resolve the captured playback selection once. Never redirect an old
        // request to an output that became active while it was waiting.
        guard audio.defaultOutput() == request.outputID else {
            throw ControlError.failed("The audio output changed. Try again.")
        }
        let devices = audio.devices()
        guard let active = devices.first(where: { $0.id == request.outputID }) else {
            throw ControlError.failed("No active audio output was found.")
        }
        if let independent = AudioRouting.independentOutput(active: active, displays: monitors.values.map(\.identity), devices: devices) {
            return try adjustDevice(independent, request: request)
        }

        let monitor = try monitor(for: request.display)
        if !request.display.builtIn && monitor.hardwareVolume {
            if request.action == .mute { return try monitor.toggleMute() }
            guard let current = request.absolute != nil ? monitor.volume : monitor.currentVolume() else {
                throw ControlError.failed("Couldn’t read monitor volume.")
            }
            let target = request.absolute ?? monitor.volumeTarget(current: current, adjustment: request.adjustment)
            try monitor.setVolume(target)
            return target
        }
        guard let device = audio.matched(request.display, devices: devices) else {
            throw ControlError.failed("Speaker volume isn’t supported for this display.")
        }
        return try adjustDevice(device, request: request)
    }
    private func adjustDevice(_ device: AudioDevice, request: Request) throws -> Double {
        let action = request.action
        guard let current = self.audio.volume(device.id) else { throw ControlError.failed("Volume control isn’t supported for this device.") }
        if action == .mute {
            if let muted = self.audio.muted(device.id) {
                try self.audio.setMute(device.id, value: !muted)
                return muted ? current : 0
            }
            let target: Double
            if current > 0 { self.priorVolumes[device.uid] = current; target = 0 }
            else { target = self.priorVolumes.removeValue(forKey: device.uid) ?? 0.25 }
            try self.audio.setVolume(device.id, value: target)
            return target
        }
        if self.audio.muted(device.id) == true { try self.audio.setMute(device.id, value: false) }
        let target = request.absolute ?? min(1, max(0, current + request.adjustment))
        try self.audio.setVolume(device.id, value: target)
        return target
    }
}
