import AppKit
import ApplicationServices
import CDeviceSupport
import IOKit.hid

@MainActor final class MouseController: ObservableObject {
    @Published var enabled = false
    @Published var trusted = AXIsProcessTrusted()
    @Published var inputAllowed = IOHIDCheckAccess(kIOHIDRequestTypeListenEvent) == kIOHIDAccessTypeGranted
    @Published var lastButton: Int?
    @Published var activeProfileName = "Default"
    @Published var frontmostBundleID = ""
    @Published var status = "Paused. Your mouse behaves normally."
    @Published var hardwareStatus = "Looking for a Logitech mouse…"
    @Published var hardwareName = "Logitech mouse"
    @Published var hardwareBusy = false
    @Published var hardwareConnected = false
    @Published var waitingForAccessibility = false
    @Published var wheelSeen = false
    @Published var granolaEnabled = false
    @Published var granolaListening = false
    @Published var granolaPressed = false
    @Published var granolaStatus = "Hold-to-dictate is off."
    @Published var supportedThumbControls: [Int] = []
    @Published var thumbPressCount = 0
    @Published var thumbReleaseCount = 0
    @Published var auxiliaryPressCount = 0
    @Published var wheelEventCount = 0
    @Published var thumbSessionID = UUID()
    @Published var dpi: Int?
    @Published var dpiMinimum = 200
    @Published var dpiMaximum = 8000
    @Published var dpiStep = 50
    @Published var battery: Int?
    var profiles: [MouseProfile] = [MouseProfile()] { didSet { refreshProfile() } }
    var onAction: ((MouseAction) -> Void)?
    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private var observer: NSObjectProtocol?
    private var permissionTimer: Timer?
    private var previousReport: Data?
    private var granolaSettings = GranolaThumbSettings()
    private var thumbMonitor: ThumbButtonMonitor?
    private var thumbGeneration = 0
    private var keyHold = KeyHoldState()
    private let queue = DispatchQueue(label: "studio.hidpp")
    private var hardwareIdentifier: UInt64 = 0
    private var profile = MouseProfile()
    private struct Press { let rule: ButtonRule; let down: CGEvent; var dx: Double = 0; var dy: Double = 0 }
    private var pressed: [Int: Press] = [:]
    private let marker: Int64 = 0x4453545544494f
    private let diagnosticsURL: URL
    var controlPermissionName: String {
        ProcessInfo.processInfo.operatingSystemVersion.majorVersion >= 27 ? "Device Control and Data Access" : "Accessibility"
    }

    init(diagnosticsURL: URL? = nil) {
        self.diagnosticsURL = diagnosticsURL ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("DeviceStudio/mouse-status.json")
        frontmostBundleID = NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? ""
        observer = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] notification in
            let bundleID = (notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.bundleIdentifier ?? ""
            Task { @MainActor in self?.frontmostBundleID = bundleID; self?.refreshProfile() }
        }
        // HID access is determined by actually opening the device. The general
        // event-listening preflight can deny access even when HID++ is available.
        connectHardware()
        permissionTimer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refreshPermissions() }
        }
    }
    private func refreshProfile() {
        profile = ProfileResolver.resolve(profiles, bundleID: frontmostBundleID)
        activeProfileName = profile.name
    }
    func refreshPermissions() {
        let previouslyTrusted = trusted
        let previouslyAllowed = inputAllowed
        trusted = AXIsProcessTrusted()
        inputAllowed = IOHIDCheckAccess(kIOHIDRequestTypeListenEvent) == kIOHIDAccessTypeGranted
        if enabled && !trusted { disable(); status = "Paused because the \(controlPermissionName) permission was removed." }
        if trusted && waitingForAccessibility { waitingForAccessibility = false; enable() }
        if inputAllowed && !previouslyAllowed && !hardwareConnected && !hardwareBusy { connectHardware() }
        if !trusted && granolaListening { stopGranola(); granolaStatus = "Waiting for the \(controlPermissionName) permission." }
        if granolaEnabled && trusted && ((!previouslyTrusted) || (inputAllowed && !previouslyAllowed)) { startGranola() }
        reportStatus()
    }
    func requestAccessibility() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        trusted = AXIsProcessTrustedWithOptions(options)
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
    }
    func requestInput() {
        _ = IOHIDRequestAccess(kIOHIDRequestTypeListenEvent)
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent")!)
    }
    func enable() {
        refreshPermissions()
        guard trusted else {
            waitingForAccessibility = true
            status = "Waiting for the \(controlPermissionName) permission. Mappings start as soon as it’s granted."
            requestAccessibility(); reportStatus(); return
        }
        waitingForAccessibility = false
        guard tap == nil else { return }
        let types: [CGEventType] = [.otherMouseDown, .otherMouseUp, .otherMouseDragged, .mouseMoved, .scrollWheel]
        let mask = types.reduce(CGEventMask(0)) { $0 | (1 << $1.rawValue) }
        let context = Unmanaged.passUnretained(self).toOpaque()
        tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap, eventsOfInterest: mask, callback: { _, type, event, context in
            guard let context else { return Unmanaged.passUnretained(event) }
            let controller = Unmanaged<MouseController>.fromOpaque(context).takeUnretainedValue()
            return controller.handle(type: type, event: event)
        }, userInfo: context)
        guard let tap else { status = "macOS wouldn’t start the mappings. Remove Device Studio from \(controlPermissionName) in System Settings, add it again, then retry."; reportStatus(); return }
        source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true); enabled = true
        status = "On. The profile follows the frontmost app."
        reportStatus()
    }
    func disable() {
        waitingForAccessibility = false
        if let tap { CGEvent.tapEnable(tap: tap, enable: false); CFMachPortInvalidate(tap) }
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        tap = nil; source = nil; pressed.removeAll(); enabled = false
        status = "Paused. Your mouse behaves normally."
        reportStatus()
    }
    private func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            // Fail open. The menu bar can be used to explicitly enable again.
            DispatchQueue.main.async { self.disable(); self.status = "macOS interrupted the mappings, so they were paused. Turn them on to resume." }
            return Unmanaged.passUnretained(event)
        }
        if event.getIntegerValueField(.eventSourceUserData) == marker { return Unmanaged.passUnretained(event) }
        let button = Int(event.getIntegerValueField(.mouseEventButtonNumber))
        switch type {
        case .otherMouseDown:
            lastButton = button
            auxiliaryPressCount += 1
            reportStatus()
            if let rule = profile.rules.first(where: { $0.button == button && $0.captures }) {
                guard let copy = event.copy() else { return Unmanaged.passUnretained(event) }
                pressed[button] = Press(rule: rule, down: copy); return nil
            }
        case .mouseMoved, .otherMouseDragged:
            for (key, var press) in pressed where press.rule.hasGesture {
                press.dx += Double(event.getIntegerValueField(.mouseEventDeltaX))
                press.dy += Double(event.getIntegerValueField(.mouseEventDeltaY))
                pressed[key] = press
            }
            if type == .otherMouseDragged && pressed[button] != nil { return nil }
        case .otherMouseUp:
            if let press = pressed.removeValue(forKey: button) {
                switch press.rule.releaseBehavior(dx: press.dx, dy: press.dy) {
                case .action(let action): DispatchQueue.main.async { self.perform(action) }
                case .nativeClick:
                    // A gesture-enabled button still keeps its ordinary short click.
                    if let up = event.copy() {
                        DispatchQueue.main.async {
                            for replay in [press.down, up] { replay.setIntegerValueField(.eventSourceUserData, value: self.marker); replay.post(tap: .cgSessionEventTap) }
                        }
                    }
                case .suppress: break
                }
                return nil
            }
        case .scrollWheel:
            wheelEventCount += 1
            if !wheelSeen { wheelSeen = true; reportStatus() }
            if event.getIntegerValueField(.scrollWheelEventIsContinuous) == 0 || profile.includeContinuousScroll {
                let vertical = profile.scrollSpeed * (profile.reverseVertical ? -1 : 1)
                let horizontal = profile.scrollSpeed * (profile.reverseHorizontal ? -1 : 1)
                scale(event, fields: [.scrollWheelEventDeltaAxis1, .scrollWheelEventFixedPtDeltaAxis1, .scrollWheelEventPointDeltaAxis1], by: vertical)
                scale(event, fields: [.scrollWheelEventDeltaAxis2, .scrollWheelEventFixedPtDeltaAxis2, .scrollWheelEventPointDeltaAxis2], by: horizontal)
            }
        default: break
        }
        return Unmanaged.passUnretained(event)
    }
    private func scale(_ event: CGEvent, fields: [CGEventField], by multiplier: Double) {
        guard multiplier != 1 else { return }
        for field in fields {
            let old = event.getIntegerValueField(field)
            guard old != 0 else { continue }
            var value = Int64((Double(old) * multiplier).rounded())
            if value == 0 { value = Double(old) * multiplier > 0 ? 1 : -1 }
            event.setIntegerValueField(field, value: value)
        }
    }
    func perform(_ action: MouseAction) {
        var shortcut = action.shortcut
        switch action.kind {
        case .passthrough: return
        case .cameraPreset: onAction?(action); return
        case .back: shortcut = Shortcut(keyCode: 33, modifiers: CGEventFlags.maskCommand.rawValue, label: "⌘[")
        case .forward: shortcut = Shortcut(keyCode: 30, modifiers: CGEventFlags.maskCommand.rawValue, label: "⌘]")
        case .missionControl: shortcut = Shortcut(keyCode: 126, modifiers: CGEventFlags.maskControl.rawValue, label: "⌃↑")
        case .desktop: shortcut = Shortcut(keyCode: 103, modifiers: 0, label: "F11")
        case .shortcut: break
        }
        guard let shortcut, let source = CGEventSource(stateID: .privateState) else { return }
        for down in [true, false] {
            let event = CGEvent(keyboardEventSource: source, virtualKey: shortcut.keyCode, keyDown: down)
            event?.flags = CGEventFlags(rawValue: shortcut.modifiers)
            event?.setIntegerValueField(.eventSourceUserData, value: marker)
            event?.post(tap: .cghidEventTap)
        }
    }
    func connectHardware() {
        guard !hardwareBusy else { return }
        hardwareBusy = true; hardwareStatus = "Looking for a Logitech mouse…"
        reportStatus()
        queue.async { [weak self] in
            guard let self else { return }
            let hardware = ds_mouse_open()
            var success = hardware.map { ds_mouse_probe($0) == 0 } ?? false
            if !success, let hardware { success = ds_mouse_probe(hardware) == 0 }
            var name = "Logitech mouse", dpi: Int32 = 0, min: Int32 = 0, max: Int32 = 0, step: Int32 = 0
            var battery: Int32 = -1, hasDPI = false
            var thumbControls: [Int] = []
            if success, let hardware {
                name = String(cString: ds_mouse_name(hardware)); battery = ds_mouse_battery(hardware)
                hasDPI = ds_mouse_dpi(hardware, &dpi, &min, &max, &step) == 0
                var controls = [DSMouseControl](repeating: DSMouseControl(), count: 64)
                let count = ds_mouse_controls(hardware, &controls, 64)
                if count > 0 {
                    thumbControls = controls.prefix(Int(count)).filter { [0x01a0, 0x00c3].contains(Int($0.cid)) && $0.flags & 0x20 != 0 }.map { Int($0.cid) }
                }
            }
            let identifier = success ? hardware.map { ds_mouse_identifier($0) } ?? 0 : 0
            let result = (name, dpi, min, max, step, battery, hasDPI)
            let capabilities = thumbControls
            let connected = success
            if let hardware { ds_mouse_close(hardware) }
            DispatchQueue.main.async {
                self.hardwareBusy = false; self.hardwareName = result.0
                self.hardwareConnected = connected
                self.supportedThumbControls = capabilities
                self.hardwareIdentifier = identifier
                self.battery = result.5 >= 0 ? Int(result.5) : nil
                self.dpi = result.6 ? Int(result.1) : nil
                if result.6 { self.dpiMinimum = Int(result.2); self.dpiMaximum = Int(result.3); self.dpiStep = Int(result.4) }
                self.hardwareStatus = connected ? (result.6 ? "Connected over HID++." : "Connected over HID++. This mouse doesn’t report an adjustable pointer speed.") : "No reply from a Logitech mouse. Wake it by moving or clicking, then connect again."
                self.reportStatus()
                // Start the long-lived listener after transient discovery. Both
                // clients use root feature requests while probing a receiver.
                self.startGranola()
            }
        }
    }
    func setDPI(_ value: Int) {
        guard !hardwareBusy else { return }; hardwareBusy = true
        let expectedIdentifier = hardwareIdentifier
        queue.async { [weak self] in
            guard let self else { return }
            // IOHID run-loop registration must be opened and closed on this same thread.
            let hardware = ds_mouse_open()
            defer { if let hardware { ds_mouse_close(hardware) } }
            let connected = hardware.map { ds_mouse_probe($0) == 0 && ds_mouse_identifier($0) == expectedIdentifier } ?? false
            let result = connected ? hardware.map { ds_mouse_set_dpi($0, Int32(value)) } ?? -1 : -1
            var current: Int32 = 0, min: Int32 = 0, max: Int32 = 0, step: Int32 = 0
            let read = connected ? hardware.map { ds_mouse_dpi($0, &current, &min, &max, &step) } ?? -1 : -1
            let readback = current
            DispatchQueue.main.async {
                self.hardwareBusy = false
                if read == 0 { self.dpi = Int(readback) }
                self.hardwareStatus = result == 0 && read == 0 && readback == value ? "Pointer speed set to \(value) DPI." : "The mouse didn’t confirm the change. Refresh and try again."
                self.reportStatus()
            }
        }
    }
    func configureGranola(_ settings: GranolaThumbSettings) {
        guard settings != granolaSettings else { return }
        stopGranola()
        granolaSettings = settings; granolaEnabled = settings.enabled
        if settings.enabled { startGranola() }
        else { granolaStatus = "Hold-to-dictate is off. The thumb button’s previous behavior has been restored." }
        reportStatus()
    }
    func startGranola() {
        guard granolaEnabled, thumbMonitor == nil else { return }
        guard !hardwareBusy else { granolaStatus = "Checking the mouse connection…"; reportStatus(); return }
        guard trusted else { granolaStatus = "Waiting for the \(controlPermissionName) permission."; reportStatus(); return }
        guard let granolaURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.granola.app") else {
            granolaStatus = "Install Granola to use hold-to-dictate."; reportStatus(); return
        }
        if NSRunningApplication.runningApplications(withBundleIdentifier: "com.granola.app").isEmpty {
            let configuration = NSWorkspace.OpenConfiguration(); configuration.activates = false
            NSWorkspace.shared.openApplication(at: granolaURL, configuration: configuration) { [weak self] _, error in
                guard let error else { return }
                DispatchQueue.main.async { self?.stopGranola(); self?.granolaStatus = "Granola could not start: \(error.localizedDescription)"; self?.reportStatus() }
            }
        }
        thumbGeneration += 1
        thumbSessionID = UUID()
        let token = thumbGeneration
        let monitor = ThumbButtonMonitor(onButton: { [weak self] pressed in
            DispatchQueue.main.async {
                guard let self, self.thumbGeneration == token else { return }
                if self.granolaPressed != pressed {
                    if pressed { self.thumbPressCount += 1 } else { self.thumbReleaseCount += 1 }
                }
                self.setGranolaKey(pressed: pressed)
            }
        }, onState: { [weak self] ready, message in
            DispatchQueue.main.async {
                guard let self, self.thumbGeneration == token else { return }
                self.granolaListening = ready; self.granolaStatus = message
                if !ready { self.thumbMonitor?.stop(); self.thumbMonitor = nil; self.setGranolaKey(pressed: false) }
                self.reportStatus()
            }
        })
        thumbMonitor = monitor; granolaStatus = "Connecting to the MX Master thumb button…"
        monitor.start(cid: granolaSettings.controlID)
        reportStatus()
    }
    func reconnectGranola() { stopGranola(); refreshPermissions(); startGranola() }
    private func stopGranola(wait: Bool = false) {
        let monitor = thumbMonitor
        thumbGeneration += 1; thumbMonitor = nil
        granolaListening = false; setGranolaKey(pressed: false)
        monitor?.stop(wait: wait)
    }
    private func setGranolaKey(pressed: Bool) {
        guard let transition = keyHold.update(pressed: pressed) else { return }
        let down = transition == .press
        // Match Granola's configured shortcut, rather than inferring it from the
        // printed keycap. Modifier keys generate flagsChanged events.
        let modifier = granolaSettings.modifier
        if let event = GranolaKeyEvent.make(pressed: down, modifier: modifier, currentFlags: CGEventSource.flagsState(.combinedSessionState), oppositeKeyHeld: CGEventSource.keyState(.combinedSessionState, key: modifier.oppositeKeyCode)) {
            event.post(tap: .cghidEventTap)
        }
        granolaPressed = down
        reportStatus()
    }
    // Written by the GUI process itself, so these permissions and hardware results
    // do not accidentally describe a Terminal-launched diagnostic process instead.
    private func reportStatus() {
        let report: [String: Any] = [
            "processID": ProcessInfo.processInfo.processIdentifier,
            "appPath": Bundle.main.bundleURL.path,
            "accessibility": trusted, "inputMonitoringPreflight": inputAllowed,
            "mappingsEnabled": enabled, "waitingForAccessibility": waitingForAccessibility,
            "eventTapActive": tap.map { CGEvent.tapIsEnabled(tap: $0) } ?? false,
            "hardwareConnected": hardwareConnected, "hardwareBusy": hardwareBusy,
            "hardwareName": hardwareName, "dpi": dpi as Any? ?? NSNull(),
            "battery": battery as Any? ?? NSNull(), "lastButton": lastButton as Any? ?? NSNull(),
            "wheelSeen": wheelSeen, "status": status, "hardwareStatus": hardwareStatus,
            "granolaEnabled": granolaEnabled, "granolaListening": granolaListening,
            "granolaPressed": granolaPressed, "granolaStatus": granolaStatus,
            "granolaControlID": granolaSettings.controlID, "granolaModifier": granolaSettings.modifier.rawValue
        ]
        do {
            let data = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
            guard data != previousReport else { return }
            let directory = diagnosticsURL.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try data.write(to: diagnosticsURL, options: .atomic)
            previousReport = data
        } catch { NSLog("Mouse diagnostics could not be saved: %@", error.localizedDescription) }
    }
    func revealInstalledApp() { NSWorkspace.shared.activateFileViewerSelecting([Bundle.main.bundleURL]) }
    func shutdown() { permissionTimer?.invalidate(); stopGranola(wait: true); disable(); queue.sync {} }
}
