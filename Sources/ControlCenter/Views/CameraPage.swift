import SwiftUI

struct CameraPage: View {
    @EnvironmentObject private var model: AppModel
    @ObservedObject var camera: CameraController
    @ViewState<String> private var presetName = ""
    @ViewState<CameraPreset?> private var presetToDelete: CameraPreset?

    var body: some View {
        Group {
            if camera.devices.isEmpty {
                ContentUnavailableView {
                    Label("No Camera Connected", systemImage: "web.camera")
                } description: {
                    Text("Plug in your camera and it will appear here.")
                }
            } else {
                // The preview stays pinned above the scrolling controls, so the
                // picture is always visible while a slider further down moves.
                VStack(spacing: 0) {
                    if camera.previewing {
                        preview
                            .padding([.horizontal, .top], 20)
                            .transition(.opacity)
                    }
                    controlsForm
                }
                .animation(.default, value: camera.previewing)
            }
        }
        .navigationTitle("Camera")
        .toolbar {
            ToolbarItemGroup {
                if camera.devices.count > 1 {
                    Picker("Camera", selection: selectedCamera) {
                        ForEach(camera.devices, id: \.uniqueID) { Text($0.localizedName).tag($0.uniqueID) }
                    }
                    .disabled(camera.busy)
                }
                Button(action: camera.refreshDevices) {
                    Label("Reload", systemImage: "arrow.clockwise")
                }
                .help("Read the camera’s settings again")
                .disabled(camera.busy)
            }
        }
        .confirmationDialog(
            "Delete “\(presetToDelete?.name ?? "")”?",
            isPresented: Binding(get: { presetToDelete != nil }, set: { if !$0 { presetToDelete = nil } })
        ) {
            Button("Delete Preset", role: .destructive) {
                model.settings.cameraPresets.removeAll { $0.id == presetToDelete?.id }
                presetToDelete = nil
            }
        } message: {
            Text("Mouse buttons assigned to this preset will stop doing anything.")
        }
    }

    private var selectedCamera: Binding<String> {
        Binding(get: { camera.selectedID }, set: { camera.select($0) })
    }

    private var preview: some View {
        CameraPreview(session: camera.session)
            .aspectRatio(16 / 9, contentMode: .fit)
            .background(.black)
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .frame(maxHeight: 320)
    }

    private var controlsForm: some View {
        Form {
            Section {
                Toggle(isOn: Binding(get: { camera.previewing }, set: { $0 ? camera.startPreview() : camera.stopPreview() })) {
                    Text("Live preview")
                    Text("Shown only in this window. Nothing is recorded.")
                }
                .disabled(camera.busy && !camera.previewing)
            } header: {
                Text(camera.name)
            } footer: {
                statusFooter
            }
            if camera.controls.isEmpty {
                Section {
                    if camera.busy {
                        HStack(spacing: 8) {
                            ProgressView().controlSize(.small)
                            Text("Reading camera settings…").foregroundStyle(.secondary)
                        }
                    } else {
                        Text("This camera doesn’t offer image controls here. Device Studio adjusts Elgato cameras over USB; other cameras are preview-only.")
                            .foregroundStyle(.secondary)
                    }
                }
            } else {
                presetsSection
                ForEach(ControlGroup.allCases, id: \.self) { group in
                    let controls = group.controls(in: camera.controls)
                    if !controls.isEmpty {
                        Section(group.title) {
                            ForEach(controls) { CameraControlRow(control: $0, camera: camera) }
                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
    }

    private var statusFooter: some View {
        VStack(alignment: .leading, spacing: 4) {
            if !camera.message.isEmpty { Text(camera.message).textSelection(.enabled) }
            if camera.name.contains("USB2") {
                Text("Connected at USB 2 speed. A USB 3 cable and port unlock higher resolutions and frame rates.")
            }
        }
        .font(.subheadline)
        .foregroundStyle(.secondary)
        .multilineTextAlignment(.leading)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var presetsSection: some View {
        Section {
            ForEach(model.settings.cameraPresets.filter { $0.deviceID == camera.selectedID }) { preset in
                LabeledContent {
                    Button("Apply") { camera.apply(preset) }
                        .disabled(camera.busy)
                    Button(role: .destructive) { presetToDelete = preset } label: {
                        Image(systemName: "trash")
                    }
                    .buttonStyle(.borderless)
                    .help("Delete preset")
                } label: {
                    Text(preset.name)
                    Text(preset.values.count == 1 ? "1 setting" : "\(preset.values.count) settings")
                }
            }
            HStack {
                TextField("New preset", text: $presetName, prompt: Text("Name the current look"))
                    .labelsHidden()
                    .onSubmit(savePreset)
                Button("Save Preset", action: savePreset)
                    .disabled(presetName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || camera.busy)
            }
        } header: {
            Text("Presets")
        } footer: {
            SectionFooter("Saves every setting below. Presets live on this Mac, not in the camera, and can be assigned to mouse buttons.")
        }
    }

    private func savePreset() {
        model.savePreset(name: presetName)
        presetName = ""
    }
}

/// Groups the flat list of UVC controls the camera reports into the sections shown on screen.
private enum ControlGroup: CaseIterable {
    case exposure, color, image, lens, other

    var title: String {
        switch self {
        case .exposure: return "Exposure"
        case .color: return "Color"
        case .image: return "Image"
        case .lens: return "Lens"
        case .other: return "Other"
        }
    }

    /// Control names in display order.
    private var names: [String] {
        switch self {
        case .exposure: return ["Auto exposure", "Exposure", "Gain", "Backlight compensation", "Power line frequency"]
        case .color: return ["Auto white balance", "White balance", "Saturation"]
        case .image: return ["Brightness", "Contrast", "Sharpness", "Gamma"]
        case .lens: return ["Auto focus", "Focus", "Zoom"]
        case .other: return []
        }
    }

    func controls(in all: [CameraControl]) -> [CameraControl] {
        if self == .other {
            let known = Set(ControlGroup.allCases.flatMap(\.names))
            return all.filter { !known.contains($0.name) }
        }
        return names.compactMap { name in all.first { $0.name == name } }
    }
}

private struct CameraControlRow: View {
    let control: CameraControl
    @ObservedObject var camera: CameraController
    @ViewState<Double> private var draft = 0.0

    var body: some View {
        Group {
            if control.isToggle {
                Toggle(title, isOn: Binding(get: { control.value == 1 }, set: { camera.set(control, value: $0 ? 1 : 0) }))
            } else if control.name == "Auto exposure" {
                Picker(title, selection: value) {
                    ForEach(exposureModes, id: \.0) { Text($0.1).tag($0.0) }
                }
            } else if control.name == "Power line frequency" {
                Picker(title, selection: value) {
                    if control.raw.minimum == 0 { Text("Off").tag(0) }
                    Text("50 Hz").tag(1)
                    Text("60 Hz").tag(2)
                }
            } else if control.raw.minimum < control.raw.maximum {
                LabeledContent(title) {
                    ValueSlider(value: $draft, range: control.range, readout: isAutomatic ? "Auto" : String(Int(draft.rounded()))) {
                        camera.set(control, value: Int(draft.rounded()))
                    }
                    .disabled(isAutomatic)
                }
            } else {
                LabeledContent(title, value: String(control.value))
            }
        }
        .disabled(camera.busy || control.raw.writable == 0)
        .onAppear { draft = Double(control.value) }
        .onChange(of: control.value) { _, new in draft = Double(new) }
    }

    private var title: String {
        switch control.name {
        case "Auto exposure": return "Exposure mode"
        case "Auto white balance": return "Automatic white balance"
        case "Auto focus": return "Autofocus"
        case "Power line frequency": return "Anti-flicker"
        default: return control.name
        }
    }

    private var value: Binding<Int> {
        Binding(get: { control.value }, set: { camera.set(control, value: $0) })
    }

    /// UVC reports the supported exposure modes as a bitmask in the control's step field.
    private var exposureModes: [(Int, String)] {
        [(1, "Manual"), (2, "Automatic"), (4, "Shutter priority"), (8, "Aperture priority")]
            .filter { Int(control.raw.step) & $0.0 != 0 || $0.0 == control.value }
    }

    /// Whether the camera currently drives this value itself, making the slider read-only.
    private var isAutomatic: Bool {
        let partnerName: String
        switch control.name {
        case "White balance": partnerName = "Auto white balance"
        case "Exposure": partnerName = "Auto exposure"
        case "Focus": partnerName = "Auto focus"
        default: return false
        }
        guard let partner = camera.controls.first(where: { $0.name == partnerName }) else { return false }
        // Exposure mode 1 is manual; the two toggles use 1 for automatic.
        return partnerName == "Auto exposure" ? partner.value != 1 : partner.value == 1
    }
}
