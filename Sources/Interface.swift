import SwiftUI
import AppKit

struct DisplayCardState: Identifiable {
    let identity: DisplayIdentity
    var brightness: Double?
    var volume: Double?
    var muted = false
    var brightnessUnit: Double = 0
    var volumeUnit: Double = 0
    var id: String { identity.stableID }
    var name: String { identity.builtIn ? "Mac display" : identity.name }
}

final class InterfaceModel: ObservableObject {
    @Published var displays: [DisplayCardState] = []
    @Published var loading = true
    @Published var permissionGranted = AXIsProcessTrusted()
    @Published var keyboardActive = false
    @Published var error: String?
    @Published var activeAudio: ControlCoordinator.Output?
    @Published private(set) var controlsLayout = ControlsLayout(contentHeight: 200)
    var panelHeight: CGFloat { controlsLayout.height }
    var controlsLayoutChanged: (() -> Void)?

    func recordContentHeight(_ height: CGFloat) {
        updateLayout(ControlsLayout(contentHeight: height, maximumHeight: controlsLayout.maximumHeight))
    }
    func measureControls(maximumHeight: CGFloat = ControlsLayout.maximumHeight) {
        let host = NSHostingView(rootView: ControlsContent(model: self).fixedSize(horizontal: false, vertical: true))
        updateLayout(ControlsLayout(contentHeight: host.fittingSize.height, maximumHeight: maximumHeight))
    }
    private func updateLayout(_ layout: ControlsLayout) {
        guard layout != controlsLayout, layout.contentHeight > 0 else { return }
        controlsLayout = layout
        controlsLayoutChanged?()
    }
    @Published var enabled = UserDefaults.standard.object(forKey: "keyboardEnabled") as? Bool ?? true {
        didSet { UserDefaults.standard.set(enabled, forKey: "keyboardEnabled"); preferencesChanged?() }
    }
    @Published var showMenuBarIcon = UserDefaults.standard.object(forKey: "showMenuBarIcon") as? Bool ?? true {
        didSet { UserDefaults.standard.set(showMenuBarIcon, forKey: "showMenuBarIcon"); preferencesChanged?() }
    }
    @Published var launchAtLogin = false
    @Published var loginNeedsApproval = false
    @Published var setupStep = 0
    var setupComplete: Bool { UserDefaults.standard.bool(forKey: "setupComplete") }
    var preferencesChanged: (() -> Void)?
    var changeLogin: ((Bool) -> Void)?
    var changeLevel: ((DisplayIdentity, Bool, Double) -> Void)?
    var changeOutputLevel: ((AudioDevice, Double) -> Void)?
    var toggleMute: ((DisplayIdentity) -> Void)?
    var detect: (() -> Void)?
    var requestPermission: (() -> Void)?
    var openLoginSettings: (() -> Void)?
    var openSettings: (() -> Void)?
    var finishSetup: (() -> Void)?
    var quit: (() -> Void)?

    func supportDescription(_ display: DisplayCardState) -> String {
        if loading { return "Detecting…" }
        switch (display.brightness != nil, display.volume != nil) {
        case (true, true): return "Brightness & volume"
        case (true, false): return "Brightness"
        case (false, true): return "Volume"
        case (false, false): return "No controls detected"
        }
    }

    func binding(_ display: DisplayCardState, brightness: Bool) -> Binding<Double> {
        Binding(get: {
            let current = self.displays.first { $0.id == display.id }
            return (brightness ? current?.brightness : current?.volume) ?? 0
        }, set: { value in
            let value = (value * 100).rounded() / 100
            guard let index = self.displays.firstIndex(where: { $0.id == display.id }) else { return }
            if brightness { self.displays[index].brightness = value }
            else { self.displays[index].volume = value; self.displays[index].muted = false }
            self.changeLevel?(display.identity, brightness, value)
        })
    }
    func outputBinding() -> Binding<Double> {
        Binding(get: { self.activeAudio?.volume ?? 0 }, set: { value in
            let value = (value * 100).rounded() / 100
            guard let output = self.activeAudio else { return }
            self.activeAudio = ControlCoordinator.Output(device: output.device, volume: value, muted: false)
            self.changeOutputLevel?(output.device, value)
        })
    }
}

private struct SymbolButton: View {
    let symbol: String
    let help: String
    let action: () -> Void
    var body: some View {
        Button(action: action) { Image(systemName: symbol).font(.system(size: 14)).frame(width: 26, height: 26) }
            .buttonStyle(.plain).foregroundStyle(.secondary).help(help).accessibilityLabel(help)
    }
}

private struct PreferenceRow: View {
    let title: String
    let binding: Binding<Bool>
    var body: some View {
        HStack {
            Text(title)
            Spacer(minLength: 20)
            Toggle(title, isOn: binding).labelsHidden().toggleStyle(.switch).controlSize(.small)
        }.frame(maxWidth: .infinity)
    }
}

private struct ControlsHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

struct ControlsView: View {
    @ObservedObject var model: InterfaceModel
    private var content: some View {
        ControlsContent(model: model)
            .fixedSize(horizontal: false, vertical: true)
            .background(GeometryReader { geometry in
                Color.clear.preference(key: ControlsHeightKey.self, value: geometry.size.height)
            })
    }
    var body: some View {
        Group {
            if model.controlsLayout.scrolls {
                ScrollView(.vertical, showsIndicators: false) { content }
                    .scrollBounceBehavior(.basedOnSize)
            } else {
                content
            }
        }
        .frame(width: ControlsLayout.width, height: model.panelHeight, alignment: .top)
        .onPreferenceChange(ControlsHeightKey.self) { model.recordContentHeight($0) }
    }
}

struct ControlsContent: View {
    @ObservedObject var model: InterfaceModel
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Tandem").font(.system(size: 14, weight: .semibold))
                Spacer()
                SymbolButton(symbol: "gearshape", help: "Settings") { model.openSettings?() }
            }.padding(.horizontal, 20).padding(.top, 15).padding(.bottom, 9)
            if !model.permissionGranted {
                HStack(spacing: 8) {
                    Image(systemName: "keyboard").foregroundStyle(.orange)
                    Text("Allow keyboard control").font(.caption)
                    Spacer()
                    Button("Allow") { model.requestPermission?() }.controlSize(.small)
                }.padding(.horizontal, 20).padding(.bottom, 10)
            }
            if model.displays.isEmpty {
                VStack(spacing: 12) {
                    if model.loading { ProgressView().controlSize(.small); Text("Detecting displays…") }
                    else { Image(systemName: "display").font(.largeTitle); Text("No display connected"); Button("Detect again") { model.detect?() } }
                }.font(.callout).foregroundStyle(.secondary).frame(maxWidth: .infinity).padding(35)
            } else {
                VStack(spacing: 12) {
                    ForEach(model.displays) { display in
                        VStack(alignment: .leading, spacing: 14) {
                            HStack(spacing: 8) {
                                Image(systemName: display.identity.builtIn ? "laptopcomputer" : "display")
                                    .font(.system(size: 14)).foregroundStyle(.secondary)
                                Text(display.name).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                                Spacer()
                            }
                            level(display, brightness: true)
                            if model.activeAudio == nil, display.volume != nil { level(display, brightness: false) }
                        }.padding(16).background(.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 12))
                    }
                }.padding(.horizontal, 16).padding(.bottom, 12)
            }
            if let output = model.activeAudio {
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Image(systemName: "headphones").foregroundStyle(.secondary)
                        Text(output.device.name).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                        Spacer()
                        if output.volume != nil {
                            Text(output.volume.map { "\(Int(($0 * 100).rounded()))%" } ?? "").font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary)
                        } else { Text("Unsupported").font(.caption).foregroundStyle(.secondary) }
                    }
                    HStack(spacing: 10) {
                        SymbolButton(symbol: output.muted ? "speaker.slash" : "speaker.wave.2", help: output.muted ? "Unmute" : "Mute") {
                            if let display = model.displays.first { model.toggleMute?(display.identity) }
                        }
                        Slider(value: model.outputBinding(), in: 0...1).controlSize(.small).tint(.primary)
                            .accessibilityLabel("\(output.device.name) volume")
                    }.disabled(output.volume == nil || model.loading)
                }.padding(16).background(.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 12))
                    .padding(.horizontal, 16).padding(.bottom, 12)
            }
            if let error = model.error {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "exclamationmark.circle").foregroundStyle(.orange)
                    Text(error).font(.caption).fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                    SymbolButton(symbol: "xmark", help: "Dismiss message") { model.error = nil }
                }.padding(.horizontal, 20).padding(.bottom, 12)
            }
        }.frame(width: ControlsLayout.width, alignment: .top)
    }
    private func level(_ display: DisplayCardState, brightness: Bool) -> some View {
        let value = brightness ? display.brightness : display.volume
        return VStack(spacing: 5) {
            HStack {
                Text(brightness ? "Brightness" : "Volume").font(.system(size: 11)).foregroundStyle(.secondary)
                Spacer()
                if value != nil {
                    Text(value.map { "\(Int(($0 * 100).rounded()))%" } ?? "")
                        .font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary)
                } else { Text("Unsupported").font(.caption).foregroundStyle(.secondary) }
            }
            HStack(spacing: 10) {
                if brightness {
                    Image(systemName: "sun.max").frame(width: 26, height: 26).foregroundStyle(.secondary)
                } else {
                    SymbolButton(symbol: display.muted ? "speaker.slash" : "speaker.wave.2", help: display.muted ? "Unmute" : "Mute") {
                        model.toggleMute?(display.identity)
                    }.disabled(value == nil || model.loading)
                }
                Slider(value: model.binding(display, brightness: brightness), in: 0...1)
                    .controlSize(.small).tint(.primary).disabled(value == nil || model.loading)
                    .accessibilityLabel("\(display.name) \(brightness ? "brightness" : "volume")")
            }
        }
    }
}

struct SettingsView: View {
    @ObservedObject var model: InterfaceModel
    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            HStack { Text("Settings").font(.title2.weight(.semibold)); Spacer(); Text("Tandem").foregroundStyle(.secondary) }
            ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: 22) {
            VStack(alignment: .leading, spacing: 14) {
                preference("Launch at login", Binding(get: { model.launchAtLogin }, set: { model.changeLogin?($0) }))
                if model.loginNeedsApproval { Button("Allow in Login Items…") { model.openLoginSettings?() } }
                preference("Show menu bar icon", $model.showMenuBarIcon)
                Text("When the icon is hidden, open the app from Applications to reach the controls.")
                    .font(.caption).foregroundStyle(.secondary)
                Divider()
                preference("Use keyboard brightness and volume keys", $model.enabled)
                HStack {
                    Label(model.permissionGranted ? "Accessibility access granted" : "Keyboard control needs permission", systemImage: model.permissionGranted ? "checkmark.circle" : "keyboard")
                        .font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    if !model.permissionGranted { Button("Allow…") { model.requestPermission?() } }
                }
            }.toggleStyle(.switch)
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("Displays").font(.headline)
                    Spacer()
                    if model.loading { ProgressView().controlSize(.small).frame(width: 26, height: 26) }
                    else { SymbolButton(symbol: "arrow.clockwise", help: "Detect displays again") { model.detect?() } }
                }
                ForEach(model.displays) { display in
                    HStack {
                        Image(systemName: display.identity.builtIn ? "laptopcomputer" : "display").foregroundStyle(.secondary)
                        Text(display.name)
                        Spacer()
                        Text(model.supportDescription(display))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            if let error = model.error { Text(error).font(.caption).foregroundStyle(.orange) }
            }.frame(maxWidth: .infinity, alignment: .leading)
            }
            Divider()
            HStack {
                Spacer()
                Button("Quit") { model.quit?() }
            }
        }.padding(26).frame(width: 480, height: 480)
    }
    private func preference(_ title: String, _ binding: Binding<Bool>) -> some View {
        PreferenceRow(title: title, binding: binding)
    }
}

struct SetupView: View {
    @ObservedObject var model: InterfaceModel
    private let titles = ["Setup", "Keyboard access", "Displays", "Startup settings"]
    private let symbols = ["slider.horizontal.3", "keyboard", "display.2", "checkmark.circle"]
    var body: some View {
        VStack(spacing: 22) {
            HStack(spacing: 6) {
                ForEach(0..<4) { index in Capsule().fill(index <= model.setupStep ? Color.primary : Color.primary.opacity(0.12)).frame(width: 32, height: 3) }
                Spacer()
                Text("\(model.setupStep + 1) / 4").font(.caption).foregroundStyle(.secondary)
            }
            Image(systemName: symbols[model.setupStep]).font(.system(size: 44, weight: .light)).padding(.top, 4)
            Text(titles[model.setupStep]).font(.system(size: 24, weight: .semibold))
            Group {
                switch model.setupStep {
                case 0:
                    VStack(spacing: 14) {
                        Text("Adjust display brightness and volume from the keyboard or the menu bar.")
                    }.multilineTextAlignment(.center)
                case 1:
                    VStack(spacing: 14) {
                        Text("Accessibility access is required to use the brightness and volume keys.")
                            .multilineTextAlignment(.center)
                        if model.permissionGranted { Label("Access granted", systemImage: "checkmark.circle.fill").foregroundStyle(.green) }
                        else { Button("Allow in System Settings") { model.requestPermission?() }.buttonStyle(.borderedProminent) }
                        Text("This step updates automatically once access is granted.").font(.caption).foregroundStyle(.secondary)
                    }
                case 2:
                    VStack(spacing: 10) {
                        if model.loading { ProgressView().controlSize(.small) }
                        ForEach(model.displays) { display in
                            HStack {
                                Image(systemName: display.identity.builtIn ? "laptopcomputer" : "display")
                                Text(display.name); Spacer()
                                Text(model.supportDescription(display)).font(.caption).foregroundStyle(.secondary)
                            }.padding(12).background(.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 10))
                        }
                        if !model.loading && model.displays.isEmpty { Text("No displays found yet.").foregroundStyle(.secondary) }
                        Button("Detect displays again") { model.detect?() }.disabled(model.loading)
                    }
                default:
                    VStack(alignment: .leading, spacing: 16) {
                        PreferenceRow(title: "Launch at login", binding: Binding(get: { model.launchAtLogin }, set: { model.changeLogin?($0) }))
                        Divider()
                        PreferenceRow(title: "Show menu bar icon", binding: $model.showMenuBarIcon)
                    }.toggleStyle(.switch)
                }
            }.font(.system(size: 13)).frame(maxWidth: .infinity, minHeight: 120, alignment: .top)
            if let error = model.error { Text(error).font(.caption).foregroundStyle(.orange) }
            Spacer(minLength: 0)
            HStack {
                if model.setupStep > 0 { Button("Back") { model.setupStep -= 1 } }
                Spacer()
                if model.setupStep == 1 && !model.permissionGranted {
                    Button("Use the menu for now") { model.setupStep += 1 }.buttonStyle(.link)
                }
                Button(model.setupStep == 3 ? "Finish" : "Continue") {
                    if model.setupStep == 3 { model.finishSetup?() }
                    else { model.setupStep += 1 }
                }.buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
                    .disabled((model.setupStep == 1 && !model.permissionGranted) || (model.setupStep == 2 && model.loading))
            }
        }.padding(30).frame(width: 500, height: 420)
    }
}
