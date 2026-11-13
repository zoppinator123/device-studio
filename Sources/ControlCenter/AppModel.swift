import AppKit
import Combine
import AVFoundation

@MainActor final class AppModel: ObservableObject {
    let camera = CameraController()
    let mouse: MouseController
    let meetings: MeetingRecorder
    let store: SettingsStore
    @Published var settings = Settings()
    @Published var error: String?
    @Published var selectedProfile: UUID?
    @Published var selectedPage = Page.setup
    @Published var granolaInstalled = false
    private var subscription: AnyCancellable?
    private var canSave = true
    init() {
        let preview = CommandLine.arguments.contains("--setup-preview")
        let previewURL = preview ? FileManager.default.temporaryDirectory.appendingPathComponent("DeviceStudio-setup-preview-\(UUID().uuidString)/settings.json") : nil
        store = SettingsStore(url: previewURL)
        mouse = MouseController(diagnosticsURL: store.url.deletingLastPathComponent().appendingPathComponent("mouse-status.json"))
        meetings = MeetingRecorder(root: store.url.deletingLastPathComponent().appendingPathComponent("Meetings", isDirectory: true))
        do { settings = try store.load() }
        catch { self.error = "Could not read saved settings. Your existing file has been preserved at \(store.url.path). \(error.localizedDescription)"; canSave = false }
        if canSave { do { try store.save(settings) } catch { self.error = "Could not create settings file: \(error.localizedDescription)" } }
        selectedProfile = settings.profiles.first?.id
        mouse.profiles = settings.profiles
        mouse.configureGranola(settings.granolaThumb)
        selectedPage = settings.setup.isComplete(binding: settings.granolaThumb) ? .overview : .setup
        // `--page <name>` opens a specific page, for screenshots and UI work.
        if let flag = CommandLine.arguments.firstIndex(of: "--page"), CommandLine.arguments.indices.contains(flag + 1),
           let page = Page(rawValue: CommandLine.arguments[flag + 1]) {
            selectedPage = page
        }
        refreshSetupStatus()
        // Saved button mappings should work after every launch without a trip to the menu bar.
        if !preview, settings.profiles.contains(where: { $0.rules.contains(where: \.captures) }) { mouse.enable() }
        mouse.onAction = { [weak self] action in
            guard let self else { return }
            if action.kind == .toggleRecording { self.toggleRecording(); return }
            guard let preset = self.settings.cameraPresets.first(where: { $0.id == action.presetID }) else { return }
            self.camera.apply(preset)
        }
        meetings.settings = settings.meetings
        meetings.recoverInterruptedRecordings()
        subscription = $settings.dropFirst().debounce(for: .milliseconds(300), scheduler: DispatchQueue.main).sink { [weak self] settings in
            guard let self else { return }
            self.mouse.profiles = settings.profiles
            self.mouse.configureGranola(settings.granolaThumb)
            self.meetings.settings = settings.meetings
            guard self.canSave else { return }
            do { try self.store.save(settings) } catch { self.error = "Could not save settings: \(error.localizedDescription)" }
        }
    }
    func savePreset(name: String) {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, !camera.controls.isEmpty, !camera.busy else { return }
        settings.cameraPresets.append(CameraPreset(name: name, deviceID: camera.selectedID, values: Dictionary(uniqueKeysWithValues: camera.controls.map { ($0.id, $0.value) })))
    }
    var setupFacts: SetupFacts {
        SetupFacts(mouseConnected: mouse.hardwareConnected, supportedThumbControls: mouse.supportedThumbControls,
                   cameraConnected: !camera.selectedID.isEmpty, cameraControlsAvailable: !camera.controls.isEmpty,
                   controlAccess: mouse.trusted, hardwareAccess: mouse.inputAllowed || mouse.hardwareConnected,
                   cameraAccess: camera.permission == .authorized, granolaInstalled: granolaInstalled)
    }
    func refreshSetupStatus() {
        granolaInstalled = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.granola.app") != nil
        camera.permission = AVCaptureDevice.authorizationStatus(for: .video)
        mouse.refreshPermissions()
    }
    func openGranola() {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.granola.app") else {
            NSWorkspace.shared.open(URL(string: "https://www.granola.ai/download")!); return
        }
        NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
    }
    func finishSetup(evidence: SetupEvidence) {
        guard SetupPolicy.blocker(step: .test, progress: settings.setup, facts: setupFacts, evidence: evidence) == nil else { return }
        settings.setup.completedAt = Date()
        settings.setup.verifiedBinding = settings.setup.goals.granola ? settings.granolaThumb : nil
        settings.setup.move(to: .complete)
        if settings.setup.goals.camera { camera.stopPreview() }
    }
    func addAppProfile() {
        let picker = NSOpenPanel(); picker.directoryURL = URL(fileURLWithPath: "/Applications")
        picker.allowedContentTypes = [.applicationBundle]; picker.canChooseDirectories = false
        picker.message = "Choose the application that will activate this mouse profile."
        guard picker.runModal() == .OK, let url = picker.url, let bundleID = Bundle(url: url)?.bundleIdentifier else { return }
        if let existing = settings.profiles.first(where: { $0.bundleID == bundleID }) { selectedProfile = existing.id; return }
        var profile = settings.profiles.first(where: { $0.bundleID == nil }) ?? MouseProfile()
        profile.id = UUID(); profile.bundleID = bundleID; profile.name = url.deletingPathExtension().lastPathComponent
        settings.profiles.append(profile); selectedProfile = profile.id
    }
    /// Start or stop from the menu bar or a mouse button. The first recording always goes through the
    /// explanation on the Meetings page, never straight to the system permission prompts.
    func toggleRecording() {
        if meetings.isRecording { meetings.stop(); return }
        guard settings.meetings.explainerAccepted else {
            selectedPage = .meetings
            meetings.showExplainer = true
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        meetings.settings = settings.meetings
        meetings.start(settings: settings.meetings)
    }
    func shutdown() {
        meetings.stop()
        mouse.shutdown(); camera.shutdown()
        if canSave { do { try store.save(settings) } catch { NSLog("Settings save failed: %@", error.localizedDescription) } }
    }
}
