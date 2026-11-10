import SwiftUI

struct MousePage: View {
    @EnvironmentObject private var model: AppModel
    @ObservedObject var mouse: MouseController
    @ViewState<Bool> private var confirmRemoveProfile = false

    var body: some View {
        Form {
            deviceSection
            mappingsSection
            profileSection
            if let index = model.settings.profiles.firstIndex(where: { $0.id == model.selectedProfile }) {
                ButtonsSection(profile: $model.settings.profiles[index], mouse: mouse)
                ScrollSection(profile: $model.settings.profiles[index])
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Mouse")
    }

    // MARK: Device

    private var deviceSection: some View {
        Section {
            DetailRow(
                symbol: "computermouse.fill",
                title: mouse.hardwareConnected ? mouse.hardwareName : "No Logitech mouse found",
                detail: mouse.hardwareStatus
            ) {
                if mouse.hardwareBusy {
                    ProgressView().controlSize(.small)
                } else if let battery = mouse.battery {
                    Label("\(battery)%", systemImage: batterySymbol(battery))
                        .foregroundStyle(.secondary)
                        .help("Battery level")
                }
                Button(mouse.hardwareConnected ? "Refresh" : "Connect", action: mouse.connectHardware)
                    .disabled(mouse.hardwareBusy)
            }
            if let dpi = mouse.dpi {
                PointerSpeedRow(mouse: mouse, current: dpi)
            }
            if !mouse.hardwareConnected && !mouse.inputAllowed && !mouse.hardwareBusy {
                PermissionNotice(
                    message: "Mouse awake but still not found? macOS may be blocking the connection. Allow Input Monitoring, then quit and reopen Device Studio.",
                    actionTitle: "Allow Input Monitoring…",
                    action: mouse.requestInput
                )
            }
        } footer: {
            SectionFooter("Read directly from the mouse. Its onboard settings, such as SmartShift and haptics, are never changed.")
        }
    }

    private func batterySymbol(_ level: Int) -> String {
        switch level {
        case 88...: return "battery.100percent"
        case 63...: return "battery.75percent"
        case 38...: return "battery.50percent"
        case 13...: return "battery.25percent"
        default: return "battery.0percent"
        }
    }

    // MARK: Mappings

    private var mappingsSection: some View {
        Section {
            Toggle(isOn: Binding(
                get: { mouse.enabled || mouse.waitingForAccessibility },
                set: { $0 ? mouse.enable() : mouse.disable() }
            )) {
                Text("Button and scroll mappings")
                Text(mouse.status)
            }
            if !mouse.trusted {
                PermissionNotice(
                    message: "Mappings need the \(mouse.controlPermissionName) permission to read and replace mouse events.",
                    actionTitle: "Open Settings…",
                    action: mouse.requestAccessibility
                )
            }
        } footer: {
            SectionFooter("Applies to every connected mouse. Left and right clicks are never remapped.")
        }
    }

    // MARK: Profiles

    private var selectedProfileIsRemovable: Bool {
        model.settings.profiles.first { $0.id == model.selectedProfile }?.bundleID != nil
    }

    private var profileSection: some View {
        Section {
            Picker("Editing profile", selection: $model.selectedProfile) {
                ForEach(model.settings.profiles) { Text($0.name).tag(Optional($0.id)) }
            }
            HStack {
                Button("Add App Profile…", action: model.addAppProfile)
                if selectedProfileIsRemovable {
                    Button("Remove Profile", role: .destructive) { confirmRemoveProfile = true }
                }
                Spacer()
                Text("Active now: \(mouse.activeProfileName)")
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text("Profiles")
        } footer: {
            SectionFooter("An app profile takes over while that app is frontmost. Everything else uses Default.")
        }
        .confirmationDialog("Remove this profile?", isPresented: $confirmRemoveProfile) {
            Button("Remove Profile", role: .destructive) {
                model.settings.profiles.removeAll { $0.id == model.selectedProfile && $0.bundleID != nil }
                model.selectedProfile = model.settings.profiles.first?.id
            }
        } message: {
            Text("Its button and scroll settings will be deleted.")
        }
    }
}

// MARK: - Pointer speed

private struct PointerSpeedRow: View {
    @ObservedObject var mouse: MouseController
    let current: Int
    @ViewState<Double> private var draft = 0.0

    var body: some View {
        LabeledContent("Pointer speed") {
            ValueSlider(value: $draft, range: Double(mouse.dpiMinimum)...Double(mouse.dpiMaximum), readout: "\(snapped) DPI") {
                mouse.setDPI(snapped)
            }
            .disabled(mouse.hardwareBusy)
        }
        .onAppear { draft = Double(current) }
        .onChange(of: current) { _, new in draft = Double(new) }
    }

    /// The slider position rounded to a step the sensor supports.
    private var snapped: Int {
        let step = max(1, mouse.dpiStep)
        let steps = ((draft - Double(mouse.dpiMinimum)) / Double(step)).rounded()
        return min(mouse.dpiMaximum, mouse.dpiMinimum + Int(steps) * step)
    }
}

// MARK: - Buttons

private struct ButtonsSection: View {
    @Binding var profile: MouseProfile
    @ObservedObject var mouse: MouseController

    private static let assignableButtons = 2...31

    var body: some View {
        Section {
            ForEach($profile.rules) { $rule in
                ButtonRuleRow(rule: $rule, availableButtons: availableButtons(for: rule)) {
                    profile.rules.removeAll { $0.id == rule.id }
                }
            }
            HStack {
                Button("Add Button", action: addRule)
                    .disabled(nextFreeButton == nil)
                Spacer()
                Text(identifyHint)
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text("Buttons")
        } footer: {
            SectionFooter("Some buttons are handled inside the mouse and never reach macOS. Check that a button shows up as “Last pressed” before assigning it.")
        }
    }

    private var identifyHint: String {
        guard mouse.enabled else { return "Turn on mappings to identify buttons as you press them" }
        guard let button = mouse.lastButton else { return "Press a mouse button to identify it" }
        return "Last pressed: \(ButtonRule(button: button).label)"
    }

    private func availableButtons(for rule: ButtonRule) -> [Int] {
        Self.assignableButtons.filter { number in
            number == rule.button || !profile.rules.contains { $0.button == number }
        }
    }

    private var nextFreeButton: Int? {
        Self.assignableButtons.first { number in !profile.rules.contains { $0.button == number } }
    }

    private func addRule() {
        if let number = nextFreeButton { profile.rules.append(ButtonRule(button: number)) }
    }
}

private struct ButtonRuleRow: View {
    @Binding var rule: ButtonRule
    let availableButtons: [Int]
    let onRemove: () -> Void
    @ViewState<Bool> private var showGestures = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Picker("Button", selection: $rule.button) {
                    ForEach(availableButtons, id: \.self) { Text(ButtonRule(button: $0).label).tag($0) }
                }
                .labelsHidden()
                .fixedSize()
                .frame(width: 140, alignment: .leading)
                Image(systemName: "arrow.right")
                    .foregroundStyle(.tertiary)
                    .accessibilityHidden(true)
                ActionEditor(action: $rule.action)
                Spacer()
                Button(role: .destructive, action: onRemove) {
                    Image(systemName: "trash")
                }
                .buttonStyle(.borderless)
                .help("Remove this button")
            }
            DisclosureGroup(isExpanded: $showGestures) {
                VStack(alignment: .leading, spacing: 8) {
                    Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 6) {
                        gestureRow("Drag up", symbol: "arrow.up", action: $rule.up)
                        gestureRow("Drag down", symbol: "arrow.down", action: $rule.down)
                        gestureRow("Drag left", symbol: "arrow.left", action: $rule.left)
                        gestureRow("Drag right", symbol: "arrow.right", action: $rule.right)
                    }
                    Text("Hold the button, drag a short distance, and release. A plain click still runs the action above. Once any direction is assigned, the others do nothing.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.top, 6)
            } label: {
                Text(gestureSummary)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
    }

    private var gestureSummary: String {
        let assigned = [rule.up, rule.down, rule.left, rule.right].filter(\.isConfigured).count
        return assigned == 0 ? "Drag gestures" : "Drag gestures · \(assigned) assigned"
    }

    private func gestureRow(_ title: String, symbol: String, action: Binding<MouseAction>) -> some View {
        GridRow {
            Label(title, systemImage: symbol)
            ActionEditor(action: action)
        }
    }
}

/// Picks what a click or gesture does, plus the extra detail some actions need.
private struct ActionEditor: View {
    @EnvironmentObject private var model: AppModel
    @Binding var action: MouseAction

    var body: some View {
        HStack {
            Picker("Action", selection: $action.kind) {
                ForEach(ActionKind.allCases) { Text($0.title).tag($0) }
            }
            .labelsHidden()
            .fixedSize()
            if action.kind == .shortcut {
                ShortcutRecorder(shortcut: $action.shortcut)
                    .frame(width: 140, height: 24)
            }
            if action.kind == .cameraPreset {
                Picker("Preset", selection: $action.presetID) {
                    Text("Choose Preset").tag(UUID?.none)
                    ForEach(model.settings.cameraPresets) { Text($0.name).tag(Optional($0.id)) }
                }
                .labelsHidden()
                .fixedSize()
            }
        }
    }
}

// MARK: - Scrolling

private struct ScrollSection: View {
    @Binding var profile: MouseProfile

    var body: some View {
        Section {
            LabeledContent("Speed") {
                ValueSlider(value: speed, range: 0.2...4, readout: String(format: "%.1f×", profile.scrollSpeed))
            }
            Toggle("Reverse vertical scrolling", isOn: $profile.reverseVertical)
            Toggle("Reverse horizontal scrolling", isOn: $profile.reverseHorizontal)
            Toggle(isOn: $profile.includeContinuousScroll) {
                Text("Also adjust smooth scrolling")
                Text("Includes trackpads, which macOS can’t tell apart from a smooth-scrolling wheel.")
            }
        } header: {
            Text("Scrolling")
        } footer: {
            SectionFooter("Horizontal scrolling is the thumb wheel.")
        }
    }

    /// Snaps to tenths, the precision shown in the readout.
    private var speed: Binding<Double> {
        Binding(get: { profile.scrollSpeed }, set: { profile.scrollSpeed = ($0 * 10).rounded() / 10 })
    }
}
