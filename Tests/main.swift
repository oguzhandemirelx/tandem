import AppKit

var passed = 0
func expect(_ predicate: @autoclosure () -> Bool, _ message: String) {
    guard predicate() else { fputs("FAIL: \(message)\n", stderr); exit(1) }
    passed += 1
}
func display(_ id: UInt32, _ frame: CGRect) -> DisplayIdentity {
    DisplayIdentity(id: id, name: "Display \(id)", stableID: "\(id)", builtIn: id == 1, frame: frame, vendor: 1, model: 1, edidUUID: nil)
}
let external = display(3, CGRect(x: 0, y: 0, width: 1920, height: 1080))
let laptop = display(1, CGRect(x: 1920, y: 346, width: 1728, height: 1117))
let displays = [external, laptop]
expect(Routing.target(at: CGPoint(x: 400, y: 400), displays: displays)?.id == 3, "External pointer routes to external even when it is the main display")
expect(Routing.target(at: CGPoint(x: 2200, y: 700), displays: displays)?.id == 1, "Laptop pointer routes to built-in display")
expect(Routing.target(at: CGPoint(x: 2000, y: 50), displays: displays) == nil, "Gap does not accidentally route to laptop")
expect(Routing.target(at: CGPoint(x: 1920, y: 500), displays: displays)?.id == 1, "Shared boundary goes to right display")
let left = display(5, CGRect(x: -1920, y: -500, width: 1920, height: 1080))
expect(Routing.target(at: CGPoint(x: -1500, y: -200), displays: [left, laptop])?.id == 5, "Negative desktop coordinates")
expect(Routing.target(at: CGPoint(x: 400, y: 400), displays: [laptop]) == nil, "Disconnected external is never selected")
for action in MediaAction.allCases {
    expect(MediaAction.decode(subtype: 8, data1: (action.rawValue << 16) | 0xA00)?.0 == action, "Decode key-down \(action)")
    expect(MediaAction.decode(subtype: 8, data1: (action.rawValue << 16) | 0xA01)?.1 == true, "Decode autorepeat \(action)")
    expect(MediaAction.decode(subtype: 8, data1: (action.rawValue << 16) | 0xB00)?.1 == false, "Decode key-up \(action)")
}
expect(MediaAction.decode(subtype: 8, data1: (16 << 16) | 0xA00) == nil, "Play/pause passes through")
expect(MediaAction.decode(subtype: 7, data1: 0xA00) == nil, "Other event subtype passes through")
expect(MediaAction.decode(subtype: 8, data1: 0xC00) == nil, "Unknown key state passes through")
expect(Routing.stepped(0.98, direction: 1) == 1, "Brightness never above max")
expect(Routing.stepped(0.02, direction: -1) == 0, "Volume never below zero")
expect(Routing.stepped(0.5, direction: 1, fine: true) == 0.515625, "Fine increment")
expect(Routing.audioMatch(displayName: "XG2405", deviceName: "xg2405"), "Case-insensitive monitor speaker match")
expect(!Routing.audioMatch(displayName: "XG2405", deviceName: "XG2405-2"), "Similar names do not silently route to wrong speaker")
expect(!Routing.audioMatch(displayName: "", deviceName: ""), "Empty names are not matches")

expect(MediaAction.volumeUp.increment(fine: false) == 0.01, "Normal volume key is one percentage point")
expect(MediaAction.volumeDown.increment(fine: true) == -0.0025, "Fine volume key is a quarter percentage point")
expect(MediaAction.brightnessUp.increment(fine: false) == 0.0625, "Brightness key keeps its native-sized step")
let speakers = AudioDevice(id: 1, uid: "BuiltInSpeakerDevice", name: "Computer speakers", builtIn: true)
let monitorSpeaker = AudioDevice(id: 2, uid: "display-output", name: "Display 3", builtIn: false)
let bluetooth = AudioDevice(id: 3, uid: "bluetooth-headset", name: "Bluetooth headphones", builtIn: false, headphones: true)
let wired = AudioDevice(id: 4, uid: "wired-headset", name: "Headphones", builtIn: true, headphones: true)
let usb = AudioDevice(id: 5, uid: "usb-dac", name: "USB Audio", builtIn: false)
let inventory = [speakers, monitorSpeaker, bluetooth, wired, usb]
expect(AudioRouting.independentOutput(active: speakers, displays: displays, devices: inventory) == nil, "Computer speaker playback uses pointer routing")
expect(AudioRouting.independentOutput(active: monitorSpeaker, displays: displays, devices: inventory) == nil, "Monitor speaker playback uses pointer routing")
expect(AudioRouting.independentOutput(active: bluetooth, displays: displays, devices: inventory)?.id == bluetooth.id, "Selected Bluetooth headphones override pointer routing")
expect(AudioRouting.independentOutput(active: wired, displays: displays, devices: inventory)?.id == wired.id, "Wired headphones are not mistaken for built-in speakers")
expect(AudioRouting.independentOutput(active: usb, displays: displays, devices: inventory)?.id == usb.id, "Selected USB/independent output follows active device")
expect(AudioRouting.matched(laptop, devices: inventory)?.id == speakers.id, "Connected wired headphones do not make internal speaker detection ambiguous")
expect(AudioRouting.independentOutput(active: nil, displays: displays, devices: inventory) == nil, "Missing output is not assigned to a random device")

let screenRect = CGRect(x: -1920, y: 0, width: 1920, height: 1080)
let centered = WindowLayout.centered(size: CGSize(width: 500, height: 442), screen: screenRect)
expect(centered.midX == screenRect.midX && centered.midY == screenRect.midY, "Windows are geometrically centered, including negative-origin screens")
for icon in [CGRect(x: -30, y: 1060, width: 22, height: 20), CGRect(x: -1900, y: 1060, width: 22, height: 20)] {
    let rect = WindowLayout.panel(size: CGSize(width: 340, height: 410), icon: icon, visibleScreen: screenRect)
    expect(rect.maxY < icon.minY, "Menu panel opens below the menu bar")
    expect(screenRect.contains(rect), "Menu panel stays within the screen at either edge")
}

final class FakeAudio: AudioHardware {
    var selected: UInt32 = 3
    var values: [UInt32: Double] = [1: 0.4, 2: 0.3, 3: 0.5, 4: 0.6, 5: 0.7]
    var mute: [UInt32: Bool] = [:]
    var writes: [UInt32] = []
    func devices() -> [AudioDevice] { inventory }
    func defaultOutput() -> UInt32? { selected }
    func volume(_ id: UInt32) -> Double? { values[id] }
    func setVolume(_ id: UInt32, value: Double) throws { values[id] = value; writes.append(id) }
    func muted(_ id: UInt32) -> Bool? { mute[id] ?? false }
    func setMute(_ id: UInt32, value: Bool) throws { mute[id] = value; writes.append(id) }
}
let fake = FakeAudio(), coordinator = ControlCoordinator(audio: fake)
let fakeDisplay = display(65000, CGRect(x: 0, y: 0, width: 100, height: 100))
func waitFor(_ start: (@escaping () -> Void) -> Void) {
    var done = false
    start { done = true }
    let deadline = Date().addingTimeInterval(3)
    while !done && Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.01)) }
    expect(done, "Asynchronous hardware operation completes")
}
waitFor { finish in coordinator.refresh([fakeDisplay]) { _, _ in finish() } }
for active in [bluetooth, wired, usb] {
    fake.selected = active.id
    fake.writes = []
    let before = fake.values[active.id]!
    waitFor { finish in coordinator.perform(.volumeUp, display: fakeDisplay, fine: false) { result in
        expect((try? result.get()) != nil, "Selected independent output is controllable")
        finish()
    } }
    expect(abs(fake.values[active.id]! - before - 0.01) < 0.0001, "Volume key adjusts the selected independent output")
    expect(fake.writes.allSatisfy { $0 == active.id }, "No computer or monitor speaker writes occur for headphones/independent output")
    waitFor { finish in coordinator.perform(.mute, display: fakeDisplay, fine: false) { _ in finish() } }
    expect(fake.mute[active.id] == true, "Mute targets the same selected output")
    waitFor { finish in coordinator.setLevel(0.23, brightness: false, display: fakeDisplay) { _ in finish() } }
    expect(fake.values[active.id] == 0.23 && fake.mute[active.id] == false, "Panel level unmutes and changes the active output")
    expect(fake.selected == active.id, "Output selection is never changed")
}

fake.selected = bluetooth.id
fake.writes = []
coordinator.queue.suspend()
var changedOutputRejected = false
coordinator.perform(.volumeUp, display: fakeDisplay, fine: false) { result in
    if case .failure = result { changedOutputRejected = true }
}
fake.selected = wired.id
coordinator.queue.resume()
let switchDeadline = Date().addingTimeInterval(3)
while !changedOutputRejected && Date() < switchDeadline { RunLoop.main.run(until: Date().addingTimeInterval(0.01)) }
expect(changedOutputRejected, "Queued volume command is rejected if the active output changes")
expect(fake.writes.isEmpty, "Output switch never redirects a stale command to another device")
print("\(passed) final checks passed")

let caps = DDCCapabilities("(prot(monitor)model(Sample)vcp(10 62 8D(01 02) CC(01 02 0a))cmds(01 03 0C))")
expect(caps?.features[0x10] != nil, "Continuous brightness capability parsed")
expect(caps?.features[0x62] != nil, "Monitor volume capability parsed")
expect(caps?.features[0x8d] == [1, 2], "Discrete mute values parsed")
expect(caps?.features[0xcc] == [1, 2, 10], "Lowercase hexadecimal capability values parsed")
expect(caps?.commands.contains(0x0c) == true, "Save command advertisement parsed separately from VCP")
expect(DDCCapabilities("(vcp(10 62)") == nil, "Truncated capabilities rejected")
expect(DDCCapabilities("(vcp(10 zz))") == nil, "Invalid feature tokens rejected")
expect(DDCCapabilities("(vcp(10)))") == nil, "Unbalanced capability reply rejected")
expect(DDCCapabilities("(model(Test))") == nil, "Absent feature list falls back to live probes")
print("\(passed) total checks passed")

expect(ControlStep.target(current: 0.99, action: .volumeUp, fine: false) == 1, "Volume clamps at maximum")
expect(abs(ControlStep.target(current: 1, action: .volumeDown, fine: false) - 0.99) < 0.0001, "Reversing at maximum responds on the first key")
expect(ControlStep.target(current: 0, action: .brightnessDown, fine: false) == 0, "Brightness clamps at minimum")
expect(ControlStep.target(current: 0.5, action: .brightnessUp, fine: true) == 0.515625, "Built-in brightness preserves fine steps")
expect(abs(ControlStep.target(current: 0.5, action: .volumeUp, fine: true, unit: 0.01) - 0.51) < 0.0001, "DDC fine adjustment moves one native unit")
expect(abs(ControlStep.target(current: 0.5, action: .brightnessUp, fine: false, unit: 0.01) - 0.56) < 0.0001, "Preview matches integer DDC brightness rounding")

fake.selected = bluetooth.id
fake.writes = []
coordinator.queue.suspend()
var latestFinished = false
for target in [0.41, 0.42, 0.43, 0.42, 0.41, 0.40] {
    coordinator.setLevel(target, brightness: false, display: fakeDisplay) { result in
        expect((try? result.get()) == 0.40, "Only the newest pending target completes")
        latestFinished = true
    }
}
coordinator.queue.resume()
let burstDeadline = Date().addingTimeInterval(3)
while !latestFinished && Date() < burstDeadline { RunLoop.main.run(until: Date().addingTimeInterval(0.01)) }
expect(latestFinished && fake.values[bluetooth.id] == 0.40, "Direction reversal ends at the latest absolute target")
expect(fake.writes.count == 1, "Slow hardware does not accumulate obsolete repeat writes")

fake.writes = []
coordinator.queue.suspend()
var muteBarrierFinished = false
coordinator.setLevel(0.30, brightness: false, display: fakeDisplay) { _ in }
coordinator.perform(.mute, display: fakeDisplay, fine: false) { _ in }
coordinator.setLevel(0.31, brightness: false, display: fakeDisplay) { _ in muteBarrierFinished = true }
coordinator.queue.resume()
let muteDeadline = Date().addingTimeInterval(3)
while !muteBarrierFinished && Date() < muteDeadline { RunLoop.main.run(until: Date().addingTimeInterval(0.01)) }
expect(muteBarrierFinished && fake.values[bluetooth.id] == 0.31 && fake.mute[bluetooth.id] == false, "Volume after queued mute applies and unmutes in order")
expect(fake.selected == bluetooth.id, "Repeat and mute sequence preserves output selection")
print("\(passed) total checks passed")

expect(ControlsLayout(contentHeight: 420).height == 420, "Short controls fit their content")
expect(!ControlsLayout(contentHeight: 600).scrolls, "Content at the exact maximum does not scroll")
expect(ControlsLayout(contentHeight: 601).scrolls && ControlsLayout(contentHeight: 601).height == 600, "Overflow caps height and enables scrolling")
expect(ControlsLayout(contentHeight: 420, maximumHeight: 300).height == 300, "Small screens reduce the panel limit")
expect(ControlsLayout(contentHeight: 420, maximumHeight: 900).height == 420, "Large screens do not force extra empty space")
expect(WindowLayout.availablePanelHeight(icon: CGRect(x: 10, y: 400, width: 22, height: 22), visibleScreen: CGRect(x: 0, y: 0, width: 800, height: 400)) == 386, "Height limit accounts for menu and screen margins")
print("\(passed) total checks passed")
