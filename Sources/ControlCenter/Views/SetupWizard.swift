import AppKit
import AVFoundation
import Combine
import SwiftUI

/// The guided first-run flow: pick features, connect devices, grant permissions,
/// match Granola's shortcut, then prove everything works with a live check.
/// `SetupPolicy` decides when a step may be left; this view only presents it.
struct SetupWizard: View {
    @EnvironmentObject private var model: AppModel
    @ObservedObject var mouse: MouseController
    @ObservedObject var camera: CameraController
    @ViewState<SetupTestBaseline?> private var baseline: SetupTestBaseline?
    @ViewState<Bool> private var dictationConfirmed = false
    @ViewState<Bool> private var previewConfirmed = false
    @ViewState<String> private var testText = ""
    private let refresh = Timer.publish(every: 1.5, on: .main, in: .common).autoconnect()

    private var progress: SetupProgress { model.settings.setup }
    private var goals: SetupGoals { progress.goals }
    private var step: SetupStep { progress.step }
    private var stepIndex: Int { progress.steps.firstIndex(of: step) ?? 0 }

    /// What the live check has observed since "Start Check" was pressed.
    /// Counters are compared with a baseline so earlier presses can't pass the test.
    private var evidence: SetupEvidence {
        guard let baseline else { return SetupEvidence() }
        let sameConnection = baseline.thumbSession == mouse.thumbSessionID
        return SetupEvidence(
            thumbPressed: sameConnection && mouse.granolaListening && mouse.thumbPressCount > baseline.presses,
            thumbReleased: sameConnection && mouse.granolaListening && !mouse.granolaPressed && mouse.thumbReleaseCount > baseline.releases,
            dictationConfirmed: dictationConfirmed,
            buttonDetected: mouse.enabled && mouse.auxiliaryPressCount > baseline.buttons,
            wheelDetected: mouse.enabled && mouse.wheelEventCount > baseline.wheel,
            cameraVerified: progress.controlsOnly
                ? !camera.busy && !camera.controls.isEmpty && camera.controlsReadCount > baseline.cameraReads
                : camera.previewing && previewConfirmed
        )
    }

    private var blocker: String? {
        SetupPolicy.blocker(step: step, progress: progress, facts: model.setupFacts, evidence: evidence)
    }

    var body: some View {
        VStack(spacing: 0) {
            stepHeader
            Form {
                switch step {
                case .welcome: welcome
                case .devices: devices
                case .permissions: permissions
                case .shortcut: shortcut
                case .test: liveTest
                case .complete: complete
                }
            }
            .formStyle(.grouped)
            if step != .complete {
                Divider()
                footer
            }
        }
        .navigationTitle("Setup Guide")
        .onAppear { normalizeStep(); model.refreshSetupStatus() }
        .onReceive(refresh) { _ in model.refreshSetupStatus() }
        .onChange(of: model.settings.granolaThumb.modifier) { _, _ in
            resetTest()
            model.settings.setup.shortcutConfirmed = false
        }
        .onChange(of: model.settings.granolaThumb.controlID) { _, _ in resetTest() }
        .onChange(of: model.settings.granolaThumb.enabled) { _, enabled in if !enabled { resetTest() } }
        .onChange(of: model.settings.setup.goals) { _, _ in
            resetTest()
            model.settings.setup.completedAt = nil
        }
        .onChange(of: step) { _, _ in resetTest() }
    }

    // MARK: - Header and footer

    private var stepHeader: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Step \(stepIndex + 1) of \(progress.steps.count)")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Text(step.title)
                .font(.title2.weight(.semibold))
            HStack(spacing: 4) {
                ForEach(progress.steps) { item in
                    Button { model.settings.setup.step = item } label: {
                        Capsule()
                            .fill(segmentStyle(for: item))
                            .frame(height: 4)
                            // A taller hit target than the 4-point bar.
                            .padding(.vertical, 6)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .disabled(!canJump(to: item))
                    .help(item.title)
                    .accessibilityLabel(item.title)
                }
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 16)
        .padding(.bottom, 4)
    }

    private func segmentStyle(for item: SetupStep) -> AnyShapeStyle {
        if item == step { return AnyShapeStyle(.tint) }
        if item.order < step.order { return AnyShapeStyle(.tint.opacity(0.4)) }
        return AnyShapeStyle(.quaternary)
    }

    /// Steps already visited can be revisited; the summary only once setup has passed.
    private func canJump(to item: SetupStep) -> Bool {
        if item == .complete { return progress.isComplete(binding: model.settings.granolaThumb) }
        return item.order <= progress.furthestStep.order
    }

    private var footer: some View {
        HStack(spacing: 12) {
            if stepIndex > 0 {
                Button("Back") { model.settings.setup.step = progress.steps[stepIndex - 1] }
            }
            Button("Finish Later") { model.selectedPage = .overview }
                .buttonStyle(.borderless)
                .help("Your progress is saved")
            Spacer(minLength: 12)
            if let blocker {
                Text(blocker)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.trailing)
                    .lineLimit(2)
            }
            if canSkipToPermissions {
                Button("Continue to Permissions") { model.settings.setup.move(to: .permissions) }
                    .buttonStyle(.borderedProminent)
            } else {
                Button(step == .test ? "Finish Setup" : "Continue", action: advance)
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(blocker != nil)
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .background(.bar)
    }

    /// A mouse that can't be reached may simply be waiting on Input Monitoring,
    /// which is granted on the next step.
    private var canSkipToPermissions: Bool {
        step == .devices && goals.granola && !model.setupFacts.hardwareAccess && !mouse.hardwareConnected
    }

    // MARK: - Welcome

    @ViewBuilder private var welcome: some View {
        Section {
            DetailRow(symbol: "mic", title: "Hold a thumb button to dictate", detail: "Uses Granola voice typing and a Logitech MX mouse.") {
                Toggle("Hold a thumb button to dictate", isOn: $model.settings.setup.goals.granola).labelsHidden()
            }
            DetailRow(symbol: "computermouse", title: "Mouse shortcuts and scrolling", detail: "Button actions, drag gestures, wheel settings, and per-app profiles.") {
                Toggle("Mouse shortcuts and scrolling", isOn: $model.settings.setup.goals.mouseMappings).labelsHidden()
            }
            DetailRow(symbol: "web.camera", title: "Camera image controls", detail: "Exposure, color, and focus for an Elgato camera, with an optional preview.") {
                Toggle("Camera image controls", isOn: $model.settings.setup.goals.camera).labelsHidden()
            }
        } footer: {
            SectionFooter("Choose only what you need. You can run this guide again to add the rest; existing profiles and presets are kept.")
        }
        Section {
            DisclosureGroup("Compatibility and what to expect") {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Requires macOS 14 or later. Tested with an MX Master 4 on a Logitech receiver and an Elgato Facecam MK.2 over USB.")
                    Text("Other Logitech mice and Bluetooth connections are checked for the controls they report, but haven’t been tested. Button and scroll mappings affect every mouse on this Mac.")
                    Text("macOS asks you to approve input and camera access yourself. Voice typing needs Granola installed, with voice typing turned on.")
                    Text("Device Studio needs no account and keeps the camera preview on this Mac. Granola handles dictation under its own settings.")
                }
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 4)
            }
        }
    }

    // MARK: - Devices

    @ViewBuilder private var devices: some View {
        if goals.needsMouseAccess {
            Section {
                CheckRow(
                    title: mouse.hardwareConnected ? mouse.hardwareName : "Looking for a Logitech mouse",
                    detail: mouse.hardwareStatus,
                    done: mouse.hardwareConnected
                ) {
                    if mouse.hardwareBusy { ProgressView().controlSize(.small) }
                    Button("Check Again", action: mouse.connectHardware)
                        .disabled(mouse.hardwareBusy)
                }
                if goals.granola && mouse.hardwareConnected {
                    if mouse.supportedThumbControls.isEmpty {
                        CheckRow(
                            title: "No supported thumb button",
                            detail: "Try connecting through the Logitech receiver, or go back and choose mouse shortcuts instead.",
                            done: false
                        )
                    } else {
                        Picker("Thumb button", selection: $model.settings.granolaThumb.controlID) {
                            ForEach(mouse.supportedThumbControls, id: \.self) { Text(ThumbControl.name($0)).tag($0) }
                        }
                        .onAppear(perform: selectAvailableThumb)
                        .onChange(of: mouse.supportedThumbControls) { _, _ in selectAvailableThumb() }
                    }
                }
                if !mouse.hardwareConnected && !mouse.inputAllowed {
                    PermissionNotice(
                        message: "If the mouse is awake and still isn’t found, macOS may be blocking the connection.",
                        actionTitle: "Open Input Monitoring…",
                        action: mouse.requestInput
                    )
                }
            } header: {
                Text("Mouse")
            } footer: {
                SectionFooter(goals.mouseMappings
                    ? "Wake the mouse by moving it. Button and scroll mappings also work without this connection; the live check verifies them."
                    : "Wake the mouse by moving it. Use its receiver, or pair it in Bluetooth settings.")
            }
        }
        if goals.camera {
            Section("Camera") {
                CheckRow(
                    title: camera.selectedID.isEmpty ? "No camera connected" : camera.name,
                    detail: cameraDetail,
                    done: !camera.selectedID.isEmpty
                ) {
                    Button("Check Again", action: camera.refreshDevices)
                        .disabled(camera.busy)
                }
                if camera.devices.count > 1 {
                    Picker("Use camera", selection: Binding(get: { camera.selectedID }, set: { camera.select($0) })) {
                        ForEach(camera.devices, id: \.uniqueID) { Text($0.localizedName).tag($0.uniqueID) }
                    }
                    .disabled(camera.busy)
                }
            }
        }
        if goals.granola {
            Section("Granola") {
                granolaRow(detail: "You’ll match its Hold to talk shortcut in a later step.")
            }
        }
    }

    private var cameraDetail: String {
        if camera.selectedID.isEmpty { return "Plug in a camera to continue." }
        if camera.busy { return "Reading settings…" }
        if camera.controls.isEmpty { return "Preview only. This camera has no supported image controls." }
        return "\(camera.controls.count) image controls available."
    }

    private func granolaRow(detail: String) -> some View {
        CheckRow(
            title: model.granolaInstalled ? "Granola is installed" : "Granola isn’t installed",
            detail: detail,
            done: model.granolaInstalled
        ) {
            Button(model.granolaInstalled ? "Open Granola" : "Get Granola", action: model.openGranola)
        }
    }

    // MARK: - Permissions

    @ViewBuilder private var permissions: some View {
        Section {
            if goals.needsMouseAccess {
                CheckRow(
                    title: mouse.controlPermissionName,
                    detail: "Lets Device Studio read mouse buttons and press keys for you.",
                    done: mouse.trusted
                ) {
                    if !mouse.trusted { Button("Open Settings…", action: mouse.requestAccessibility) }
                }
            }
            if goals.granola {
                CheckRow(title: "Mouse connection", detail: hardwareAccessDetail, done: model.setupFacts.hardwareAccess) {
                    if !model.setupFacts.hardwareAccess {
                        Button("Open Input Monitoring…", action: mouse.requestInput)
                        Button("Retry", action: mouse.connectHardware)
                            .disabled(mouse.hardwareBusy)
                    }
                }
            }
            if goals.camera {
                CheckRow(
                    title: "Camera",
                    detail: progress.controlsOnly ? "Preview is skipped, so no camera access is needed." : "For the live preview, which is never recorded.",
                    done: camera.permission == .authorized || progress.controlsOnly
                ) {
                    if !progress.controlsOnly && camera.permission != .authorized {
                        Button("Allow…", action: camera.requestPermission)
                    }
                }
                Toggle("Skip the preview and use image controls only", isOn: $model.settings.setup.controlsOnly)
                    .disabled(camera.controls.isEmpty)
            }
        } footer: {
            SectionFooter("macOS asks you to approve each of these yourself. The checkmarks reflect what this running app can actually do, and update on their own.")
        }
        if goals.needsMouseAccess {
            Section {
                DisclosureGroup("Switch is on, but still not allowed?") {
                    VStack(alignment: .leading, spacing: 8) {
                        Group {
                            Text("An older copy or a rebuilt app can leave a stale entry behind. To refresh it:")
                            Text("1. In Privacy & Security, select Device Studio in the permission’s list and remove it with −.")
                            Text("2. Add this copy again with + and turn it on.")
                            Text("3. Quit and reopen Device Studio if macOS asks. Your progress is saved.")
                        }
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        Text(Bundle.main.bundleURL.path)
                            .font(.caption.monospaced())
                            .textSelection(.enabled)
                        Button("Show This App in Finder", action: mouse.revealInstalledApp)
                    }
                    .font(.subheadline)
                    .padding(.top, 4)
                }
            }
        }
    }

    private var hardwareAccessDetail: String {
        if mouse.inputAllowed { return "Input Monitoring is allowed." }
        if mouse.hardwareConnected { return "Already working. Input Monitoring isn’t needed for this connection." }
        return "Turn on Device Studio under Input Monitoring, then reopen the app if macOS asks."
    }

    // MARK: - Shortcut

    @ViewBuilder private var shortcut: some View {
        Section {
            granolaRow(detail: "Voice typing must be turned on in Granola.")
        }
        Section {
            NumberedStep(1, "In Granola, open Settings → Voice typing.")
            NumberedStep(2, "Under Shortcuts, find Hold to talk (not Hands-free).")
            NumberedStep(3, "Choose the same key here. If Granola uses something else, change it to Option or Command first.")
            Picker("Granola’s Hold to talk key", selection: $model.settings.granolaThumb.modifier) {
                ForEach(DictationModifier.allCases) { Text($0.title).tag($0) }
            }
            Toggle("I checked Granola, and Hold to talk matches", isOn: $model.settings.setup.shortcutConfirmed)
                .disabled(!model.granolaInstalled)
        } footer: {
            SectionFooter("Go by Granola’s setting rather than the label on your keyboard: layouts and remapped keys can differ.")
        }
    }

    // MARK: - Live check

    @ViewBuilder private var liveTest: some View {
        Section {
            LabeledContent {
                Button(baseline == nil ? "Start Check" : "Restart Check", action: startCheck)
                    .buttonStyle(.borderedProminent)
                    .disabled(goals.camera && camera.busy)
            } label: {
                Text(baseline == nil ? "Ready when you are" : "Check in progress")
                Text("Only what happens after you start counts.")
            }
        }
        if goals.granola {
            Section {
                if let baseline, baseline.thumbSession != mouse.thumbSessionID {
                    Label("The mouse reconnected. Restart the check.", systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                }
                CheckRow(
                    title: "Hold the thumb button",
                    detail: thumbHint,
                    done: evidence.thumbPressed
                )
                CheckRow(title: "Release it", detail: "The key is let go the moment you release.", done: evidence.thumbReleased)
                TextField("Voice typing test", text: $testText, prompt: Text("Dictated words appear here"), axis: .vertical)
                    .lineLimit(2...4)
                    .labelsHidden()
                Toggle("Words appeared, and Granola stopped when I let go", isOn: $dictationConfirmed)
                    .disabled(!evidence.thumbPressed || !evidence.thumbReleased)
                DisclosureGroup("The button responds, but nothing is typed") {
                    Text("Check that voice typing is on in Granola, that Hold to talk is set to \(model.settings.granolaThumb.modifier.title), and that Granola has microphone access. If the button doesn’t register at all, go back to Devices and try the other thumb button, and quit any other utility using it.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, 4)
                }
            } header: {
                Text("Dictation")
            } footer: {
                SectionFooter("The text in the field isn’t saved. Granola handles the microphone and transcript.")
            }
        }
        if goals.mouseMappings {
            Section {
                CheckRow(title: "Click the wheel or a side button", detail: "Any button other than left and right click.", done: evidence.buttonDetected)
                CheckRow(title: "Scroll the wheel", detail: "A small scroll is enough.", done: evidence.wheelDetected)
            } header: {
                Text("Mouse")
            } footer: {
                SectionFooter("The check turns on your current mappings, so buttons you have already assigned will run their actions.")
            }
        }
        if goals.camera {
            Section("Camera") {
                if progress.controlsOnly {
                    CheckRow(
                        title: "Read the camera’s settings",
                        detail: camera.busy ? "Reading…" : "\(camera.controls.count) image controls read from \(camera.name).",
                        done: evidence.cameraVerified
                    )
                } else {
                    if camera.previewing {
                        CameraPreview(session: camera.session)
                            .aspectRatio(16 / 9, contentMode: .fit)
                            .frame(maxHeight: 240)
                            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                            .frame(maxWidth: .infinity)
                    }
                    Toggle(isOn: Binding(get: { camera.previewing }, set: { $0 ? camera.startPreview() : camera.stopPreview() })) {
                        Text("Live preview")
                        if !camera.message.isEmpty { Text(camera.message) }
                    }
                    .disabled(camera.busy && !camera.previewing)
                    Toggle("I can see my camera’s picture", isOn: $previewConfirmed)
                        .disabled(!camera.previewing)
                }
            }
        }
    }

    private var thumbHint: String {
        if mouse.granolaPressed { return "Held. Speak, then release." }
        // Before the check starts, or while listening, there is nothing to report but the instruction.
        if baseline == nil || mouse.granolaListening { return "Click in the field below, then hold the button and say a few words." }
        return mouse.granolaStatus
    }

    // MARK: - Complete

    @ViewBuilder private var complete: some View {
        Section {
            if goals.granola {
                CheckRow(title: "Hold to dictate", detail: "Press and release verified, typing with \(model.settings.granolaThumb.modifier.title).", done: true)
            }
            if goals.mouseMappings {
                CheckRow(title: "Mouse shortcuts and scrolling", detail: "A button and the wheel were both detected.", done: true)
            }
            if goals.camera {
                CheckRow(title: "Camera", detail: progress.controlsOnly ? "Image controls are available." : "You confirmed the live preview.", done: true)
            }
        } footer: {
            SectionFooter(goals.needsMouseAccess
                ? "Keep Device Studio running to use your mouse features; closing the window leaves it in the menu bar. Button and scroll mappings start paused each launch, while hold to dictate resumes on its own."
                : "Open Camera to adjust the picture and save presets. Run this guide again to add mouse features later.")
        }
        Section {
            HStack {
                Button(opensCameraNext ? "Open Camera" : "Open Mouse") {
                    model.selectedPage = opensCameraNext ? .camera : .mouse
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                Button("Run Setup Again") { model.settings.setup.restart() }
            }
        }
    }

    private var opensCameraNext: Bool { goals.camera && !goals.needsMouseAccess }

    // MARK: - Flow

    private func advance() {
        guard blocker == nil else { return }
        if step == .test { model.finishSetup(evidence: evidence); return }
        if step == .shortcut {
            model.settings.granolaThumb.enabled = true
            mouse.configureGranola(model.settings.granolaThumb)
        }
        guard stepIndex + 1 < progress.steps.count else { return }
        model.settings.setup.move(to: progress.steps[stepIndex + 1])
    }

    private func startCheck() {
        resetTest()
        if goals.granola {
            model.settings.granolaThumb.enabled = true
            mouse.configureGranola(model.settings.granolaThumb)
            mouse.startGranola()
        }
        if goals.mouseMappings && !mouse.enabled { mouse.enable() }
        baseline = SetupTestBaseline(
            thumbSession: mouse.thumbSessionID,
            presses: mouse.thumbPressCount,
            releases: mouse.thumbReleaseCount,
            buttons: mouse.auxiliaryPressCount,
            wheel: mouse.wheelEventCount,
            cameraReads: camera.controlsReadCount
        )
        if goals.camera && progress.controlsOnly { camera.refreshControls() }
    }

    private func resetTest() {
        baseline = nil
        dictationConfirmed = false
        previewConfirmed = false
        testText = ""
    }

    private func selectAvailableThumb() {
        if !mouse.supportedThumbControls.contains(model.settings.granolaThumb.controlID), let first = mouse.supportedThumbControls.first {
            model.settings.granolaThumb.controlID = first
        }
    }

    /// Repairs a saved position that no longer fits the chosen features or a changed binding.
    private func normalizeStep() {
        if !progress.steps.contains(step) { model.settings.setup.step = .permissions }
        if step == .complete && !progress.isComplete(binding: model.settings.granolaThumb) {
            model.settings.setup.shortcutConfirmed = false
            model.settings.setup.completedAt = nil
            model.settings.setup.step = goals.granola ? .shortcut : .test
        }
    }
}

/// Event counters captured when a live check starts.
private struct SetupTestBaseline {
    let thumbSession: UUID
    let presses: Int
    let releases: Int
    let buttons: Int
    let wheel: Int
    let cameraReads: Int
}

/// A requirement with a checkmark that fills in once it is met.
private struct CheckRow<Trailing: View>: View {
    let title: String
    let detail: String
    let done: Bool
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: done ? "checkmark.circle.fill" : "circle.dashed")
                .font(.title3)
                .foregroundStyle(done ? AnyShapeStyle(.green) : AnyShapeStyle(.tertiary))
                .frame(width: 28)
                .accessibilityLabel(done ? "Done" : "Not done yet")
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                Text(detail)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 12)
            trailing
        }
        .padding(.vertical, 2)
    }
}

extension CheckRow where Trailing == EmptyView {
    init(title: String, detail: String, done: Bool) {
        self.init(title: title, detail: detail, done: done) { EmptyView() }
    }
}
