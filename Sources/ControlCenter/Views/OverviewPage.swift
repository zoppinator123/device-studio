import AppKit
import AVFoundation
import SwiftUI

/// The landing page: what is connected, what still needs permission, and how the app runs.
struct OverviewPage: View {
    @EnvironmentObject private var model: AppModel
    @ObservedObject var mouse: MouseController
    @ObservedObject var camera: CameraController
    @ViewState<Bool> private var showTroubleshooting = false

    var body: some View {
        Form {
            Section {
                header
                if !model.settings.setup.isComplete(binding: model.settings.granolaThumb) {
                    setupPrompt
                }
            }
            devicesSection
            permissionsSection
            backgroundSection
        }
        .formStyle(.grouped)
        .navigationTitle("Overview")
        .onAppear(perform: refreshPermissions)
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            refreshPermissions()
        }
    }

    private var header: some View {
        HStack(spacing: 14) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 56, height: 56)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text("Device Studio")
                    .font(.title2.weight(.semibold))
                Text("Camera image controls and mouse shortcuts, running entirely on this Mac.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.vertical, 4)
    }

    /// Shown until the setup guide has been completed.
    private var setupPrompt: some View {
        let progress = model.settings.setup
        let stepNumber = (progress.steps.firstIndex(of: progress.step) ?? 0) + 1
        return DetailRow(
            symbol: "checklist",
            title: "Finish setting up",
            detail: "Step \(stepNumber) of \(progress.steps.count): \(progress.step.title)"
        ) {
            Button("Continue Setup") { model.selectedPage = .setup }
                .buttonStyle(.borderedProminent)
        }
    }

    // MARK: Devices

    private var devicesSection: some View {
        Section("Devices") {
            NavigationRow(symbol: "web.camera", title: cameraTitle, detail: cameraDetail) { model.selectedPage = .camera }
            NavigationRow(symbol: "computermouse", title: mouseTitle, detail: mouseDetail) { model.selectedPage = .mouse }
            NavigationRow(symbol: "mic", title: "Hold to dictate", detail: dictationDetail) { model.selectedPage = .dictation }
        }
    }

    private var cameraTitle: String {
        camera.devices.isEmpty ? "No camera connected" : camera.name
    }

    private var cameraDetail: String {
        if camera.devices.isEmpty { return "Plug in a camera to adjust its image." }
        if camera.busy && camera.controls.isEmpty { return "Reading settings…" }
        if camera.controls.isEmpty { return "Preview only. Image controls need an Elgato camera." }
        return "\(camera.controls.count) image controls · \(model.settings.cameraPresets.count) presets"
    }

    private var mouseTitle: String {
        mouse.hardwareConnected ? mouse.hardwareName : "No Logitech mouse found"
    }

    private var mouseDetail: String {
        var parts: [String] = []
        if let battery = mouse.battery { parts.append("Battery \(battery)%") }
        if let dpi = mouse.dpi { parts.append("\(dpi) DPI") }
        parts.append(mouse.enabled ? "Mappings on" : "Mappings paused")
        return parts.joined(separator: " · ")
    }

    private var dictationDetail: String {
        guard model.settings.granolaThumb.enabled else { return "Off" }
        return mouse.granolaListening ? "On. Hold the thumb button to dictate with Granola." : mouse.granolaStatus
    }

    // MARK: Permissions

    private var permissionsSection: some View {
        Section {
            PermissionRow(
                symbol: "accessibility",
                title: mouse.controlPermissionName,
                detail: "Required for button mappings and hold to dictate.",
                state: mouse.trusted ? .allowed : .missing,
                action: mouse.requestAccessibility
            )
            PermissionRow(
                symbol: "camera",
                title: "Camera",
                detail: "Only for the live preview. Image controls work without it.",
                state: camera.permission == .authorized ? .allowed : .missing,
                action: camera.requestPermission
            )
            PermissionRow(
                symbol: "keyboard",
                title: "Input Monitoring",
                detail: "Only if macOS blocks the connection to your mouse.",
                state: mouse.inputAllowed ? .allowed : mouse.hardwareConnected ? .notNeeded : .missing,
                action: mouse.requestInput
            )
            DisclosureGroup("Permission not taking effect?", isExpanded: $showTroubleshooting) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("macOS ties each permission to one copy of the app. In System Settings → Privacy & Security, remove any existing Device Studio entry with −, then add this copy with +. After granting Input Monitoring, quit and reopen Device Studio.")
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Button("Show This App in Finder", action: mouse.revealInstalledApp)
                }
                .padding(.top, 4)
            }
        } header: {
            Text("Permissions")
        } footer: {
            SectionFooter("Each permission is requested only for the feature that needs it.")
        }
    }

    private func refreshPermissions() {
        mouse.refreshPermissions()
        camera.permission = AVCaptureDevice.authorizationStatus(for: .video)
    }

    // MARK: Background behavior

    private var backgroundSection: some View {
        Section {
            DetailRow(
                symbol: "menubar.arrow.up.rectangle",
                title: "Stays in the menu bar",
                detail: "Closing this window keeps your mappings running. Pause them or quit from the menu bar icon."
            )
            DetailRow(
                symbol: "pause.circle",
                title: "Mappings start paused",
                detail: "After each launch, turn them on from the Mouse page or the menu bar."
            )
            DetailRow(
                symbol: "lock",
                title: "Nothing leaves this Mac",
                detail: "No account and no network requests. Settings are a JSON file you can read."
            ) {
                Button("Show Settings File", action: showSettingsFile)
            }
        } header: {
            Text("How It Runs")
        } footer: {
            SectionFooter("Device Studio \(appVersion)")
        }
    }

    private var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "development build"
    }

    private func showSettingsFile() {
        let url = model.store.url
        NSWorkspace.shared.selectFile(url.path, inFileViewerRootedAtPath: url.deletingLastPathComponent().path)
    }
}

/// A device summary that opens its page when clicked.
private struct NavigationRow: View {
    let symbol: String
    let title: String
    let detail: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            DetailRow(symbol: symbol, title: title, detail: detail) {
                Image(systemName: "chevron.right")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

private struct PermissionRow: View {
    enum State { case allowed, missing, notNeeded }

    let symbol: String
    let title: String
    let detail: String
    let state: State
    let action: () -> Void

    var body: some View {
        DetailRow(symbol: symbol, title: title, detail: detail) {
            switch state {
            case .allowed:
                Label("Allowed", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            case .notNeeded:
                Text("Not needed")
                    .foregroundStyle(.secondary)
            case .missing:
                Button("Allow…", action: action)
            }
        }
    }
}
