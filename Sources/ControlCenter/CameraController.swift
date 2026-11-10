import AppKit
@preconcurrency import AVFoundation
import CDeviceSupport
import SwiftUI

struct CameraControl: Identifiable {
    var raw: DSUVCControl
    let name: String
    var id: String { "\(raw.unit):\(raw.selector)" }
    var value: Int { Int(raw.current) }
    var range: ClosedRange<Double> { Double(raw.minimum)...Double(raw.maximum) }
    var isToggle: Bool { name == "Auto white balance" || name == "Auto focus" }
}

// All mutable transport state is accessed on the camera serial queue.
private final class CameraHardware: @unchecked Sendable {
    let session = AVCaptureSession()
    var usb: OpaquePointer?
}

@MainActor final class CameraController: ObservableObject {
    @Published var devices: [AVCaptureDevice] = []
    @Published var selectedID = ""
    @Published var controls: [CameraControl] = []
    @Published var previewing = false
    @Published var busy = false
    @Published var message = ""
    @Published var controlsReadCount = 0
    @Published var permission = AVCaptureDevice.authorizationStatus(for: .video)
    var session: AVCaptureSession { hardware.session }
    private nonisolated let hardware = CameraHardware()
    private let queue = DispatchQueue(label: "studio.camera")
    private var generation = 0
    private var discovery: AVCaptureDevice.DiscoverySession?
    private var discoveryObserver: NSKeyValueObservation?
    var name: String { devices.first(where: { $0.uniqueID == selectedID })?.localizedName ?? "Elgato camera" }

    init() {
        let d = AVCaptureDevice.DiscoverySession(deviceTypes: [.external, .builtInWideAngleCamera], mediaType: .video, position: .unspecified)
        discovery = d
        discoveryObserver = d.observe(\.devices, options: [.initial, .new]) { [weak self] _, _ in
            Task { @MainActor in self?.refreshDevices() }
        }
    }
    func refreshDevices() {
        devices = discovery?.devices ?? []
        if !devices.contains(where: { $0.uniqueID == selectedID }) {
            stopPreview()
            selectedID = devices.first(where: { $0.localizedName.localizedCaseInsensitiveContains("elgato") || $0.localizedName.localizedCaseInsensitiveContains("facecam") })?.uniqueID ?? devices.first?.uniqueID ?? ""
        }
        refreshControls()
    }
    func select(_ id: String) { stopPreview(); selectedID = id; refreshControls() }
    func refreshControls(completionMessage: String? = nil) {
        guard !busy else { return }
        busy = true; controls = []; generation += 1
        let token = generation, id = selectedID
        queue.async { [weak self] in
            // The UVC transport belongs to this serial queue only.
            guard let self else { return }
            if let usb = self.hardware.usb { ds_uvc_close(usb); self.hardware.usb = nil }
            var found: [CameraControl] = []
            if id.lowercased().contains("fd9") {
                self.hardware.usb = ds_uvc_open(0x0fd9, 0)
                if let usb = self.hardware.usb {
                    let location = String(format: "0x%x", ds_uvc_location(usb))
                    // AVFoundation IDs encode the USB location followed by vendor/product.
                    if !id.lowercased().hasPrefix(location.lowercased()) { ds_uvc_close(usb); self.hardware.usb = nil }
                }
                if let usb = self.hardware.usb {
                    var raw = [DSUVCControl](repeating: DSUVCControl(), count: 32)
                    let count = ds_uvc_controls(usb, &raw, 32)
                    for var item in raw.prefix(Int(count)) {
                        let name = withUnsafePointer(to: &item.name) { $0.withMemoryRebound(to: CChar.self, capacity: 64) { String(cString: $0) } }
                        found.append(CameraControl(raw: item, name: name))
                    }
                }
            }
            let result = found
            DispatchQueue.main.async {
                guard token == self.generation else { return }
                self.controls = result; self.busy = false
                self.controlsReadCount += 1
                self.message = completionMessage ?? (result.isEmpty ? "" : "\(result.count) settings read from the camera.")
            }
        }
    }
    func set(_ control: CameraControl, value: Int) {
        guard !busy, control.raw.writable != 0 else { return }
        let step = control.name == "Auto exposure" ? 1 : max(1, Int(control.raw.step)), minimum = Int(control.raw.minimum)
        let requested = min(Int(control.raw.maximum), max(minimum, minimum + Int((Double(value-minimum)/Double(step)).rounded()) * step))
        busy = true
        queue.async { [weak self] in
            guard let self, let usb = self.hardware.usb else { DispatchQueue.main.async { self?.busy = false }; return }
            var raw = control.raw
            let result = ds_uvc_set(usb, &raw, Int32(requested))
            var readback: Int32 = 0
            let readResult = ds_uvc_get(usb, &raw, &readback)
            DispatchQueue.main.async {
                self.busy = false
                if result == 0 && readResult == 0 {
                    if let i = self.controls.firstIndex(where: { $0.id == control.id }) { self.controls[i].raw.current = readback }
                    self.message = readback == requested ? "\(control.name) set to \(readback)." : "Camera returned \(readback) for \(control.name) (requested \(requested))."
                } else { self.message = "Camera rejected \(control.name). Turn off its automatic mode or close other camera apps, then refresh. (\(result))" }
            }
        }
    }
    func apply(_ preset: CameraPreset) {
        guard !busy, preset.deviceID == selectedID else { message = "Select the camera this preset was saved for."; return }
        busy = true
        // Set automatic modes first so that manual controls can become writable.
        let selected = controls.sorted { ($0.name.hasPrefix("Auto") ? 0 : 1) < ($1.name.hasPrefix("Auto") ? 0 : 1) }
        queue.async { [weak self] in
            guard let self, let usb = self.hardware.usb else { DispatchQueue.main.async { self?.busy = false }; return }
            var failures: [String] = []
            for control in selected {
                guard let value = preset.values[control.id] else { continue }
                // When auto modes are enabled, their manual partners need no write.
                if control.name == "White balance", selected.contains(where: { $0.name == "Auto white balance" && preset.values[$0.id] == 1 }) { continue }
                if control.name == "Exposure", selected.contains(where: { $0.name == "Auto exposure" && preset.values[$0.id] != 1 && preset.values[$0.id] != nil }) { continue }
                if control.name == "Focus", selected.contains(where: { $0.name == "Auto focus" && preset.values[$0.id] == 1 }) { continue }
                var raw = control.raw, readback: Int32 = 0
                guard let encoded = Int32(exactly: value) else { failures.append(control.name); continue }
                if ds_uvc_set(usb, &raw, encoded) != 0 || ds_uvc_get(usb, &raw, &readback) != 0 || readback != value { failures.append(control.name) }
            }
            let failed = failures
            DispatchQueue.main.async {
                self.busy = false
                self.refreshControls(completionMessage: failed.isEmpty ? "Applied \(preset.name)." : "Preset partially applied. Check: \(failed.joined(separator: ", ")).")
            }
        }
    }
    func startPreview() {
        guard !previewing, !busy else { return }
        busy = true
        AVCaptureDevice.requestAccess(for: .video) { [weak self] allowed in
            Task { @MainActor in
                guard let self else { return }
                self.permission = AVCaptureDevice.authorizationStatus(for: .video)
                guard allowed else { self.busy = false; self.message = "Enable Camera access in System Settings → Privacy & Security → Camera."; return }
                guard let device = self.devices.first(where: { $0.uniqueID == self.selectedID }) else { self.busy = false; return }
                self.queue.async {
                    do {
                        let input = try AVCaptureDeviceInput(device: device)
                        self.hardware.session.beginConfiguration()
                        self.hardware.session.inputs.forEach { self.hardware.session.removeInput($0) }
                        guard self.hardware.session.canAddInput(input) else { self.hardware.session.commitConfiguration(); throw CocoaError(.featureUnsupported) }
                        self.hardware.session.addInput(input)
                        if self.hardware.session.canSetSessionPreset(.high) { self.hardware.session.sessionPreset = .high }
                        self.hardware.session.commitConfiguration(); self.hardware.session.startRunning()
                        DispatchQueue.main.async { self.previewing = self.hardware.session.isRunning; self.busy = false; self.message = self.previewing ? "Live preview on." : "The camera could not start. Close other camera apps and try again." }
                    } catch { DispatchQueue.main.async { self.busy = false; self.message = error.localizedDescription } }
                }
            }
        }
    }
    func requestPermission() {
        permission = AVCaptureDevice.authorizationStatus(for: .video)
        if permission == .denied || permission == .restricted {
            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Camera")!)
            return
        }
        AVCaptureDevice.requestAccess(for: .video) { [weak self] _ in
            Task { @MainActor in self?.permission = AVCaptureDevice.authorizationStatus(for: .video) }
        }
    }
    func stopPreview() {
        previewing = false
        queue.async { [session] in session.stopRunning(); session.beginConfiguration(); session.inputs.forEach { session.removeInput($0) }; session.commitConfiguration() }
    }
    func shutdown() { stopPreview(); queue.sync { if let usb = hardware.usb { ds_uvc_close(usb); hardware.usb = nil } } }
}

struct CameraPreview: NSViewRepresentable {
    let session: AVCaptureSession
    func makeNSView(context: Context) -> AVCaptureVideoPreviewView { AVCaptureVideoPreviewView(session: session) }
    func updateNSView(_ view: AVCaptureVideoPreviewView, context: Context) {}
}
final class AVCaptureVideoPreviewView: NSView {
    init(session: AVCaptureSession) {
        super.init(frame: .zero)
        wantsLayer = true
        let preview = AVCaptureVideoPreviewLayer(session: session); preview.videoGravity = .resizeAspect
        layer = preview
    }
    required init?(coder: NSCoder) { fatalError() }
}
