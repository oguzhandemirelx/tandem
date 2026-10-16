import AppKit
import SwiftUI
import ServiceManagement
import CoreAudio

final class AppDelegate: NSObject, NSApplicationDelegate {
    let model = InterfaceModel()
    private var status: NSStatusItem?
    private var controlsPanel: ControlsPanel?
    private var dismissMonitors: [Any] = []
    private var audioListeners: [(AudioObjectPropertyAddress, AudioObjectPropertyListenerBlock)] = []
    private let coordinator = ControlCoordinator()
    private let keyboard = KeyboardListener()
    private let hud = HUD()
    private var timer: Timer?
    private var refreshTimer: Timer?
    private var ready = false
    private var observations: [NSObjectProtocol] = []
    private var refreshGeneration = 0
    private var settingsWindow: NSWindow?
    private var setupWindow: NSWindow?
    private var controlsWindow: NSWindow?
    private var pendingFields: [String: Int] = [:]
    private var revision = 0
    private var reading = false
    private var levelsDirty = false
    private var reconcile: DispatchWorkItem?
    private var lastInput = -Double.infinity
    private var hudRevision = 0
    private var muteRestore: [String: Double] = [:]
    private var lastMenuAnchor: NSRect?
    private var openPanelAnchor: (icon: NSRect, visibleScreen: NSRect)?
    private var statusMouseDown = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard NSRunningApplication.runningApplications(withBundleIdentifier: Bundle.main.bundleIdentifier ?? "").count <= 1 else {
            NSApp.terminate(nil); return
        }
        configureInterface()
        model.controlsLayoutChanged = { [weak self] in self?.resizeControls() }
        keyboard.onAction = { [weak self] action, point, fine in self?.route(action, point: point, fine: fine) ?? false }
        keyboard.onStatus = { [weak self] active in self?.model.keyboardActive = active }
        model.preferencesChanged = { [weak self] in self?.applyPreferences() }
        model.changeLogin = { [weak self] enabled in self?.setLogin(enabled) }
        model.changeLevel = { [weak self] display, brightness, value in self?.setLevel(display, brightness: brightness, value: value) }
        model.changeOutputLevel = { [weak self] device, value in
            guard let self else { return }
            guard self.coordinator.audio.defaultOutput() == device.id, let display = self.model.displays.first else { self.readOutput(); return }
            self.setLevel(display.identity, brightness: false, value: value)
        }
        model.toggleMute = { [weak self] display in self?.perform(.mute, display: display, fine: false) }
        model.detect = { [weak self] in self?.refresh() }
        model.requestPermission = { [weak self] in self?.requestPermission() }
        model.openLoginSettings = { SMAppService.openSystemSettingsLoginItems() }
        model.openSettings = { [weak self] in self?.showSettings() }
        model.finishSetup = { [weak self] in self?.finishSetup() }
        model.quit = { NSApp.terminate(nil) }
        applyPreferences()
        refreshLogin()
        refresh()
        observations.append(NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
            object: nil, queue: .main) { [weak self] _ in self?.scheduleRefresh() })
        observations.append(NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification,
            object: nil, queue: .main) { [weak self] _ in self?.scheduleRefresh() })
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            guard let self else { return }
            self.model.permissionGranted = AXIsProcessTrusted()
            if self.model.enabled && !self.keyboard.active { _ = self.keyboard.start() }
            self.model.keyboardActive = self.keyboard.active
            self.refreshLogin()
            self.readOutput()
            self.readLevels()
        }
        if !model.setupComplete { showSetup() }
    }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if flag { return true }
        if !model.setupComplete { showSetup() }
        else { showControlsWindow() }
        return true
    }
    func applicationWillTerminate(_ notification: Notification) {
        keyboard.stop(); timer?.invalidate(); refreshTimer?.invalidate()
        dismissMonitors.forEach { NSEvent.removeMonitor($0) }
        for (var address, listener) in audioListeners {
            AudioObjectRemovePropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, .main, listener)
        }
    }
    private func configureInterface() {
        let panel = ControlsPanel(contentRect: NSRect(x: 0, y: 0, width: 340, height: 400), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.level = .popUpMenu; panel.isOpaque = false; panel.backgroundColor = .clear
        panel.isReleasedWhenClosed = false; panel.hasShadow = true
        panel.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        let effect = NSVisualEffectView()
        effect.material = .popover; effect.state = .active; effect.blendingMode = .behindWindow
        effect.wantsLayer = true; effect.layer?.cornerRadius = 12; effect.layer?.masksToBounds = true
        let host = NSHostingView(rootView: ControlsView(model: model))
        // The panel owns its size. SwiftUI must not resize the NSWindow again
        // when an observed level or the output-device row updates.
        host.sizingOptions = []
        host.translatesAutoresizingMaskIntoConstraints = false
        effect.addSubview(host)
        NSLayoutConstraint.activate([host.leadingAnchor.constraint(equalTo: effect.leadingAnchor), host.trailingAnchor.constraint(equalTo: effect.trailingAnchor), host.topAnchor.constraint(equalTo: effect.topAnchor), host.bottomAnchor.constraint(equalTo: effect.bottomAnchor)])
        panel.contentView = effect; controlsPanel = panel
        if let monitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .leftMouseUp, .rightMouseDown], handler: { [weak self] event in
            if event.type == .leftMouseUp { self?.statusMouseDown = false }
            self?.dismissPanelOutsideClick(at: Self.screenPoint(event))
        }) { dismissMonitors.append(monitor) }
        if let monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .leftMouseUp, .rightMouseDown], handler: { [weak self] event in
            guard let self else { return event }
            // The status window includes the padding beside the glyph/button.
            // Treat its entire reserved slot as one button, once per click.
            if event.type == .leftMouseUp && self.statusMouseDown {
                self.statusMouseDown = false
                return nil
            }
            if event.type == .leftMouseDown, !event.modifierFlags.contains(.command),
               let window = self.status?.button?.window, event.window === window {
                self.statusMouseDown = true
                // macOS can forward a near-miss as a synthetic click at the
                // button center. Check the real pointer before toggling so an
                // outside click cannot close on down and immediately reopen.
                if window.frame.contains(NSEvent.mouseLocation) { self.togglePopover() }
                else { self.controlsPanel?.orderOut(nil) }
                return nil
            }
            if event.type != .leftMouseUp, event.window !== self.controlsPanel { self.dismissPanelOutsideClick(at: Self.screenPoint(event)) }
            return event
        }) { dismissMonitors.append(monitor) }
        // System menu tracking can consume mouse events before global monitors.
        // Losing key status to another menu/window must dismiss this panel too.
        observations.append(NotificationCenter.default.addObserver(forName: NSWindow.didResignKeyNotification,
            object: panel, queue: .main) { [weak self] _ in self?.dismissPanelOutsideClick(at: NSEvent.mouseLocation) })
        for selector in [kAudioHardwarePropertyDefaultOutputDevice, kAudioHardwarePropertyDevices] {
            var address = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
            let listener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in self?.readOutput(); self?.readLevels() }
            if AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, .main, listener) == noErr { audioListeners.append((address, listener)) }
        }
    }
    private func applyPreferences() {
        if model.enabled { _ = keyboard.start() } else { keyboard.stop() }
        model.keyboardActive = keyboard.active
        if model.showMenuBarIcon {
            if status == nil {
                let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
                item.button?.image = AppIcon.menuBar()
                item.button?.image?.isTemplate = true
                item.button?.toolTip = "Display brightness and volume"
                item.button?.target = self; item.button?.action = #selector(togglePopover)
                status = item
            }
        } else if let item = status {
            controlsPanel?.orderOut(nil)
            NSStatusBar.system.removeStatusItem(item); status = nil
        }
    }
    private static func screenPoint(_ event: NSEvent) -> NSPoint {
        guard let point = event.cgEvent?.location else { return NSEvent.mouseLocation }
        return NSPoint(x: point.x, y: (NSScreen.screens.first?.frame.maxY ?? 0) - point.y)
    }
    private func dismissPanelOutsideClick(at point: NSPoint) {
        guard let panel = controlsPanel, panel.isVisible else { return }
        if let button = status?.button, let window = button.window {
            // Include the status item's side padding, matching the local click handler.
            if window.frame.contains(point) { return }
        }
        if !panel.frame.contains(point) { panel.orderOut(nil) }
    }
    @objc private func togglePopover() {
        guard status?.button != nil, let panel = controlsPanel else { return }
        if panel.isVisible { panel.orderOut(nil) }
        else {
            readLevels()
            readOutput()
            positionPanel(resetAnchor: true)
            panel.makeKeyAndOrderFront(nil)
        }
    }
    private func positionPanel(resetAnchor: Bool = false) {
        guard let panel = controlsPanel else { return }
        if resetAnchor || openPanelAnchor == nil {
            guard let button = status?.button, let window = button.window, let screen = window.screen else { return }
            var icon = window.convertToScreen(button.convert(button.bounds, to: nil))
            if icon.minY >= screen.visibleFrame.maxY - 2 && icon.maxY <= screen.frame.maxY + 2 {
                lastMenuAnchor = icon
            } else {
                let x = lastMenuAnchor?.midX ?? NSEvent.mouseLocation.x
                icon = NSRect(x: x - button.bounds.width / 2, y: screen.frame.maxY - NSStatusBar.system.thickness,
                              width: button.bounds.width, height: NSStatusBar.system.thickness)
            }
            // macOS can move the status item's window by a few points as menu-bar
            // focus changes. Keep the opening anchor until the next explicit open.
            openPanelAnchor = (icon, screen.visibleFrame)
            model.measureControls(maximumHeight: WindowLayout.availablePanelHeight(icon: icon, visibleScreen: screen.visibleFrame))
        }
        guard let anchor = openPanelAnchor else { return }
        let frame = WindowLayout.panel(size: CGSize(width: 340, height: model.panelHeight), icon: anchor.icon, visibleScreen: anchor.visibleScreen)
        if panel.frame != frame { panel.setFrame(frame, display: true, animate: false) }
    }
    private func resizeControls() {
        if controlsPanel?.isVisible == true { positionPanel() }
        if let window = controlsWindow, window.isVisible {
            let top = window.frame.maxY
            window.setContentSize(NSSize(width: ControlsLayout.width, height: model.panelHeight))
            window.setFrameOrigin(NSPoint(x: window.frame.minX, y: top - window.frame.height))
        }
    }
    private func makeWindow<Content: View>(title: String, view: Content, size: NSSize) -> NSWindow {
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
        window.title = title; window.isReleasedWhenClosed = false
        window.contentViewController = NSHostingController(rootView: view)
        return window
    }
    private func present(_ window: NSWindow) {
        controlsPanel?.orderOut(nil)
        for other in [settingsWindow, setupWindow, controlsWindow].compactMap({ $0 }) where other !== window { other.close() }
        let point = NSEvent.mouseLocation
        if let screen = NSScreen.screens.first(where: { $0.frame.contains(point) }) ?? NSScreen.main {
            window.setFrame(WindowLayout.centered(size: window.frame.size, screen: screen.frame), display: true)
        }
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }
    private func showSettings() {
        refreshLogin()
        if settingsWindow == nil { settingsWindow = makeWindow(title: "Tandem — Settings", view: SettingsView(model: model), size: NSSize(width: 480, height: 480)) }
        present(settingsWindow!)
    }
    private func showControlsWindow() {
        readLevels()
        let screen = NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) } ?? NSScreen.main
        model.measureControls(maximumHeight: (screen?.visibleFrame.height ?? ControlsLayout.maximumHeight) - 48)
        if controlsWindow == nil { controlsWindow = makeWindow(title: "Tandem", view: ControlsView(model: model), size: NSSize(width: 340, height: 410)) }
        controlsWindow?.setContentSize(NSSize(width: 340, height: model.panelHeight))
        present(controlsWindow!)
    }
    private func showSetup() {
        model.setupStep = 0
        settingsWindow?.close()
        if setupWindow == nil { setupWindow = makeWindow(title: "Tandem — Setup", view: SetupView(model: model), size: NSSize(width: 500, height: 420)) }
        present(setupWindow!)
    }
    private func finishSetup() {
        UserDefaults.standard.set(true, forKey: "setupComplete")
        setupWindow?.close()
        if model.showMenuBarIcon { togglePopover() } else { showControlsWindow() }
    }
    private func scheduleRefresh() {
        controlsPanel?.orderOut(nil)
        openPanelAnchor = nil
        ready = false; model.loading = true; refreshGeneration += 1
        refreshTimer?.invalidate()
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: false) { [weak self] _ in self?.refresh() }
    }
    private func refresh() {
        ready = false; model.loading = true; model.error = nil
        refreshGeneration += 1
        let generation = refreshGeneration
        model.displays = discoverDisplays().map { DisplayCardState(identity: $0) }
        coordinator.refresh(model.displays.map(\.identity)) { [weak self] capabilities, _ in
            guard let self, generation == self.refreshGeneration else { return }
            for capability in capabilities {
                if let index = self.model.displays.firstIndex(where: { $0.identity.id == capability.id }) {
                    self.model.displays[index].brightnessUnit = capability.brightnessUnit
                    self.model.displays[index].volumeUnit = capability.volumeUnit
                }
            }
            self.ready = true
            self.readOutput()
            self.readLevels()
        }
    }
    private func readLevels() {
        guard ready else { return }
        guard pendingFields.isEmpty, ProcessInfo.processInfo.systemUptime - lastInput >= 0.3 else { return }
        if reading { levelsDirty = true; return }
        reading = true
        let generation = refreshGeneration, startedRevision = revision
        coordinator.readLevels { [weak self] levels in
            guard let self else { return }
            self.reading = false
            let dirty = self.levelsDirty
            self.levelsDirty = false
            guard generation == self.refreshGeneration else { self.readLevels(); return }
            // A read queued before an edit must never move the slider backwards.
            if startedRevision == self.revision {
                for level in levels {
                    guard let index = self.model.displays.firstIndex(where: { $0.id == level.stableID }) else { continue }
                    self.model.displays[index].brightness = level.brightness
                    self.model.displays[index].volume = level.volume
                    self.model.displays[index].muted = level.muted
                }
            }
            self.model.loading = false
            if dirty { self.readLevels() }
        }
    }
    private func readOutput() {
        guard ready, pendingFields.isEmpty else { return }
        let startedRevision = revision
        coordinator.readOutput { [weak self] output in
            guard let self, startedRevision == self.revision, self.pendingFields.isEmpty else { return }
            self.model.activeAudio = output
        }
    }
    private func scheduleReconcile() {
        reconcile?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.pendingFields.isEmpty else { return }
            self.readLevels()
            self.readOutput()
        }
        reconcile = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35, execute: work)
    }
    private func field(_ display: DisplayIdentity, brightness: Bool) -> String {
        !brightness && model.activeAudio != nil ? "output.volume" : "\(display.stableID).\(brightness ? "brightness" : "volume")"
    }
    private func setLevel(_ display: DisplayIdentity, brightness: Bool, value: Double, showHUD: Bool = false) {
        guard ready else { return }
        revision += 1
        lastInput = ProcessInfo.processInfo.systemUptime
        reconcile?.cancel()
        let version = revision, field = field(display, brightness: brightness)
        pendingFields[field] = version
        let action: MediaAction = brightness ? .brightnessUp : .volumeUp
        if showHUD {
            hudRevision = version
            hud.show(display: display, action: action, value: value, title: brightness ? nil : model.activeAudio?.device.name)
        }
        coordinator.setLevel(value, brightness: brightness, display: display) { [weak self] result in
            guard let self, self.pendingFields[field] == version else { return }
            self.pendingFields.removeValue(forKey: field)
            if case .failure(let error) = result {
                self.model.error = error.localizedDescription
                if showHUD && self.hudRevision == version {
                    self.hud.show(display: display, action: action, value: nil, error: error.localizedDescription)
                }
            }
            // Read back once after input settles, never after every repeat.
            self.scheduleReconcile()
        }
    }
    private func route(_ action: MediaAction, point: CGPoint, fine: Bool) -> Bool {
        guard model.enabled, ready, let target = Routing.target(at: point, displays: model.displays.map(\.identity)) else { return false }
        perform(action, display: target, fine: fine)
        return true
    }
    private func perform(_ action: MediaAction, display: DisplayIdentity, fine: Bool) {
        guard ready, let index = model.displays.firstIndex(where: { $0.id == display.stableID }) else { return }
        if action != .mute {
            let current: Double?, unit: Double
            if action.isBrightness {
                current = model.displays[index].brightness
                unit = model.displays[index].brightnessUnit
            } else {
                current = model.activeAudio != nil ? model.activeAudio?.volume : model.displays[index].volume
                unit = model.activeAudio == nil ? model.displays[index].volumeUnit : 0
            }
            guard let current else { return }
            let target = ControlStep.target(current: current, action: action, fine: fine, unit: unit)
            if action.isBrightness { model.displays[index].brightness = target }
            else if let output = model.activeAudio {
                model.activeAudio = ControlCoordinator.Output(device: output.device, volume: target, muted: false)
            } else {
                model.displays[index].volume = target
                model.displays[index].muted = false
            }
            setLevel(display, brightness: action.isBrightness, value: target, showHUD: true)
            return
        }
        revision += 1
        lastInput = ProcessInfo.processInfo.systemUptime
        reconcile?.cancel()
        let version = revision, field = field(display, brightness: false)
        pendingFields[field] = version
        let preview: Double
        if let output = model.activeAudio {
            let muted = !output.muted
            model.activeAudio = ControlCoordinator.Output(device: output.device, volume: output.volume, muted: muted)
            preview = muted ? 0 : output.volume ?? 0
        } else {
            let muted = !model.displays[index].muted
            model.displays[index].muted = muted
            if !display.builtIn {
                if muted, let volume = model.displays[index].volume, volume > 0 { muteRestore[display.stableID] = volume }
                model.displays[index].volume = muted ? 0 : muteRestore[display.stableID] ?? 0.25
            }
            preview = muted ? 0 : model.displays[index].volume ?? 0
        }
        hudRevision = version
        hud.show(display: display, action: action, value: preview, title: model.activeAudio?.device.name)
        coordinator.perform(action, display: display, fine: fine) { [weak self] result in
            guard let self, self.pendingFields[field] == version else { return }
            self.pendingFields.removeValue(forKey: field)
            switch result {
            case .success(let value): self.applyMute(display, value: value)
            case .failure(let error):
                self.model.error = error.localizedDescription
                if self.hudRevision == version { self.hud.show(display: display, action: action, value: nil, error: error.localizedDescription) }
            }
            self.scheduleReconcile()
        }
    }
    private func applyMute(_ display: DisplayIdentity, value: Double) {
        if let output = model.activeAudio {
            model.activeAudio = ControlCoordinator.Output(device: output.device, volume: value > 0 ? value : output.volume, muted: value == 0)
            return
        }
        guard let index = model.displays.firstIndex(where: { $0.identity.stableID == display.stableID }) else { return }
        if display.builtIn {
            model.displays[index].muted = value == 0
            if value > 0 { model.displays[index].volume = value }
        } else {
            model.displays[index].volume = value
            model.displays[index].muted = value == 0
            if value > 0 { muteRestore[display.stableID] = value }
        }
    }
    private func requestPermission() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
    }
    private func refreshLogin() {
        model.launchAtLogin = SMAppService.mainApp.status == .enabled || SMAppService.mainApp.status == .requiresApproval
        model.loginNeedsApproval = SMAppService.mainApp.status == .requiresApproval
    }
    private func setLogin(_ enabled: Bool) {
        do {
            if enabled { try SMAppService.mainApp.register() }
            else { try SMAppService.mainApp.unregister() }
        } catch { model.error = error.localizedDescription }
        refreshLogin()
    }
}
