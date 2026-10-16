import CoreAudio
import Foundation

struct AudioDevice {
    let id: AudioDeviceID
    let uid: String
    let name: String
    let builtIn: Bool
    let headphones: Bool
    init(id: AudioDeviceID, uid: String, name: String, builtIn: Bool, headphones: Bool = false) {
        self.id = id; self.uid = uid; self.name = name; self.builtIn = builtIn; self.headphones = headphones
    }
}

protocol AudioHardware {
    func devices() -> [AudioDevice]
    func defaultOutput() -> AudioDeviceID?
    func volume(_ id: AudioDeviceID) -> Double?
    func setVolume(_ id: AudioDeviceID, value: Double) throws
    func muted(_ id: AudioDeviceID) -> Bool?
    func setMute(_ id: AudioDeviceID, value: Bool) throws
}

enum AudioRouting {
    static func matched(_ display: DisplayIdentity, devices: [AudioDevice]) -> AudioDevice? {
        if display.builtIn {
            let candidates = devices.filter { $0.builtIn && !$0.headphones }
            return candidates.count == 1 ? candidates[0] : nil
        }
        if let uuid = display.edidUUID {
            let candidates = devices.filter { !$0.headphones && $0.uid.caseInsensitiveCompare(uuid) == .orderedSame }
            if candidates.count == 1 { return candidates[0] }
        }
        let candidates = devices.filter { !$0.headphones && Routing.audioMatch(displayName: display.name, deviceName: $0.name) }
        return candidates.count == 1 ? candidates[0] : nil
    }
    // A connected device is relevant only when macOS has selected it for playback.
    static func independentOutput(active: AudioDevice?, displays: [DisplayIdentity], devices: [AudioDevice]) -> AudioDevice? {
        guard let active else { return nil }
        if active.headphones { return active }
        if active.builtIn { return nil }
        if displays.contains(where: { matched($0, devices: devices)?.id == active.id }) { return nil }
        return active
    }
}

extension AudioHardware {
    func matched(_ display: DisplayIdentity, devices: [AudioDevice]) -> AudioDevice? { AudioRouting.matched(display, devices: devices) }
}

enum ControlError: LocalizedError {
    case failed(String)
    var errorDescription: String? { if case .failed(let text) = self { return text }; return nil }
}

final class AudioController: AudioHardware {
    func address(_ selector: AudioObjectPropertySelector, scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeOutput,
                 channel: AudioObjectPropertyElement = kAudioObjectPropertyElementMain) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: channel)
    }
    func read<T>(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector, initial: T,
                 scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeOutput, channel: UInt32 = 0) -> T? {
        var prop = address(selector, scope: scope, channel: channel), value = initial
        var size = UInt32(MemoryLayout<T>.size)
        guard AudioObjectHasProperty(id, &prop) else { return nil }
        let result = withUnsafeMutablePointer(to: &value) { AudioObjectGetPropertyData(id, &prop, 0, nil, &size, $0) }
        guard result == noErr else { return nil }
        return value
    }
    func string(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String {
        var prop = address(selector, scope: kAudioObjectPropertyScopeGlobal)
        var value: Unmanaged<CFString>?, size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        let result = withUnsafeMutablePointer(to: &value) { AudioObjectGetPropertyData(id, &prop, 0, nil, &size, $0) }
        guard result == noErr, let value else { return "" }
        return value.takeRetainedValue() as String
    }
    func set<T>(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector, value: T,
                scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeOutput, channel: UInt32 = 0) throws {
        var prop = address(selector, scope: scope, channel: channel), data = value
        var writable: DarwinBoolean = false
        guard AudioObjectIsPropertySettable(id, &prop, &writable) == noErr, writable.boolValue else {
            throw ControlError.failed("Audio control isn’t supported on this device.")
        }
        let status = withUnsafePointer(to: &data) { AudioObjectSetPropertyData(id, &prop, 0, nil, UInt32(MemoryLayout<T>.size), $0) }
        guard status == noErr else { throw ControlError.failed("Couldn’t adjust volume (\(status)).") }
    }
    func devices() -> [AudioDevice] {
        var prop = address(kAudioHardwarePropertyDevices, scope: kAudioObjectPropertyScopeGlobal), size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &prop, 0, nil, &size) == noErr else { return [] }
        var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &prop, 0, nil, &size, &ids) == noErr else { return [] }
        return ids.compactMap { id in
            var streams = address(kAudioDevicePropertyStreams), bytes: UInt32 = 0
            guard AudioObjectGetPropertyDataSize(id, &streams, 0, nil, &bytes) == noErr, bytes > 0 else { return nil }
            let transport = read(id, kAudioDevicePropertyTransportType, initial: UInt32(0), scope: kAudioObjectPropertyScopeGlobal)
            let name = string(id, kAudioObjectPropertyName)
            let source = read(id, kAudioDevicePropertyDataSource, initial: UInt32(0))
            var streamIDs = [AudioStreamID](repeating: 0, count: Int(bytes) / MemoryLayout<AudioStreamID>.size)
            let streamResult = AudioObjectGetPropertyData(id, &streams, 0, nil, &bytes, &streamIDs)
            let terminalIsHeadphone = streamResult == noErr && streamIDs.contains {
                read($0, kAudioStreamPropertyTerminalType, initial: UInt32(0), scope: kAudioObjectPropertyScopeGlobal) == kAudioStreamTerminalTypeHeadphones
            }
            // 'hdpn' is kIOAudioOutputPortSubTypeHeadphones in the macOS SDK.
            let headphones = source == 0x6864706e || terminalIsHeadphone || name.localizedCaseInsensitiveContains("headphone") || name.localizedCaseInsensitiveContains("headset")
            return AudioDevice(id: id, uid: string(id, kAudioDevicePropertyDeviceUID), name: string(id, kAudioObjectPropertyName),
                               builtIn: transport == kAudioDeviceTransportTypeBuiltIn, headphones: headphones)
        }
    }
    func defaultOutput() -> AudioDeviceID? {
        read(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDefaultOutputDevice, initial: AudioDeviceID(0), scope: kAudioObjectPropertyScopeGlobal)
    }
    func volumeChannels(_ id: AudioDeviceID) -> [UInt32] {
        for channels: [UInt32] in [[0], [1, 2]] {
            if channels.allSatisfy({ c in
                var prop = address(kAudioDevicePropertyVolumeScalar, channel: c), writable: DarwinBoolean = false
                return AudioObjectHasProperty(id, &prop) && AudioObjectIsPropertySettable(id, &prop, &writable) == noErr && writable.boolValue
            }) { return channels }
        }
        return []
    }
    func volume(_ id: AudioDeviceID) -> Double? {
        let channels = volumeChannels(id)
        guard !channels.isEmpty else { return nil }
        let values = channels.compactMap { read(id, kAudioDevicePropertyVolumeScalar, initial: Float(0), channel: $0) }
        guard values.count == channels.count else { return nil }
        return values.reduce(0) { $0 + Double($1) } / Double(values.count)
    }
    func setVolume(_ id: AudioDeviceID, value: Double) throws {
        let channels = volumeChannels(id)
        guard !channels.isEmpty else { throw ControlError.failed("This device has no software volume control.") }
        for channel in channels { try set(id, kAudioDevicePropertyVolumeScalar, value: Float(min(1, max(0, value))), channel: channel) }
    }
    func muted(_ id: AudioDeviceID) -> Bool? {
        read(id, kAudioDevicePropertyMute, initial: UInt32(0)).map { $0 != 0 }
    }
    func setMute(_ id: AudioDeviceID, value: Bool) throws { try set(id, kAudioDevicePropertyMute, value: UInt32(value ? 1 : 0)) }
}
