import SwiftUI
import AVFoundation
import CDeviceSupport
import Darwin

@main struct DeviceStudioApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    @StateObject private var model = AppModel()

    init() {
        if CommandLine.arguments.contains("--diagnose") {
            exit(Diagnostics.run())
        }
    }

    var body: some Scene {
        WindowGroup("Device Studio", id: "main") {
            ContentView()
                .environmentObject(model)
                .onAppear { delegate.model = model }
        }
        .defaultSize(width: 920, height: 720)
        .commands { CommandGroup(replacing: .newItem) {} }

        MenuBarExtra("Device Studio", systemImage: "slider.horizontal.3") {
            MenuContent(model: model, mouse: model.mouse)
        }
    }
}

struct MenuContent: View {
    @ObservedObject var model: AppModel
    @ObservedObject var mouse: MouseController
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button("Open Device Studio") {
            openWindow(id: "main")
            NSApp.activate(ignoringOtherApps: true)
        }
        Button("Setup Guide…") {
            model.selectedPage = .setup
            openWindow(id: "main")
            NSApp.activate(ignoringOtherApps: true)
        }
        Divider()
        Toggle("Mouse Mappings", isOn: Binding(
            get: { mouse.enabled || mouse.waitingForAccessibility },
            set: { $0 ? mouse.enable() : mouse.disable() }
        ))
        Toggle("Hold to Dictate", isOn: $model.settings.granolaThumb.enabled)
        Divider()
        Text("Profile: \(mouse.activeProfileName)")
        if let battery = mouse.battery {
            Text("\(mouse.hardwareName): \(battery)%")
        }
        Divider()
        Button("Quit Device Studio") { NSApp.terminate(nil) }
            .keyboardShortcut("q")
    }
}

@MainActor final class AppDelegate: NSObject, NSApplicationDelegate {
    var model: AppModel?
    private var terminationSignal: DispatchSourceSignal?
    func applicationDidFinishLaunching(_ notification: Notification) {
        signal(SIGTERM, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
        source.setEventHandler { NSApp.terminate(nil) }
        terminationSignal = source; source.resume()
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func applicationWillTerminate(_ notification: Notification) { model?.shutdown() }
}

enum Diagnostics {
    static func run() -> Int32 {
        var failed = false
        print("Device Studio — hardware diagnostics (reads only unless a verification flag is supplied)")
        print("Camera permission: \(AVCaptureDevice.authorizationStatus(for: .video).rawValue)")
        let devices = AVCaptureDevice.DiscoverySession(deviceTypes: [.external, .builtInWideAngleCamera], mediaType: .video, position: .unspecified).devices
        for device in devices { print("Camera: \(device.localizedName) [\(device.uniqueID)]") }
        if let usb = ds_uvc_open(0x0fd9, 0) {
            defer { ds_uvc_close(usb) }
            var controls = [DSUVCControl](repeating: DSUVCControl(), count: 32)
            let count = ds_uvc_controls(usb, &controls, 32)
            print("Direct UVC: \(count) readable controls")
            for var c in controls.prefix(Int(count)) {
                let name = withUnsafePointer(to: &c.name) { $0.withMemoryRebound(to: CChar.self, capacity: 64) { String(cString: $0) } }
                print("  \(name): \(c.current) [\(c.minimum)…\(c.maximum)], step \(c.step), writable \(c.writable)")
            }
            if CommandLine.arguments.contains("--verify-uvc-write"), var control = controls.prefix(Int(count)).first(where: { $0.writable != 0 && $0.size == 2 }) {
                // Write the current value only: verify transport without changing the image.
                let result = ds_uvc_set(usb, &control, control.current)
                var readback: Int32 = 0; let read = ds_uvc_get(usb, &control, &readback)
                let passed = result == 0 && read == 0 && readback == control.current
                failed = failed || !passed
                print("UVC same-value write/readback: \(passed ? "PASS" : "FAIL")")
            }
            if CommandLine.arguments.contains("--verify-uvc-write") && !controls.prefix(Int(count)).contains(where: { $0.writable != 0 && $0.size == 2 }) { failed = true }
        } else { print("No Elgato UVC device available."); if CommandLine.arguments.contains("--verify-uvc-write") { failed = true } }
        if CommandLine.arguments.contains("--probe-mouse") {
            if let mouse = ds_mouse_open() {
                defer { ds_mouse_close(mouse) }
                if ds_mouse_probe(mouse) == 0 {
                    print("HID++ mouse: \(String(cString: ds_mouse_name(mouse)))")
                    var dpi: Int32 = 0, min: Int32 = 0, max: Int32 = 0, step: Int32 = 0
                    let result = ds_mouse_dpi(mouse, &dpi, &min, &max, &step)
                    print("DPI: result \(result), value \(dpi), range \(min)…\(max), step \(step)")
                    print("Battery: \(ds_mouse_battery(mouse))")
                    if result == 0 && CommandLine.arguments.contains("--verify-dpi-write") {
                        let write = ds_mouse_set_dpi(mouse, dpi)
                        var readback: Int32 = 0
                        let read = ds_mouse_dpi(mouse, &readback, &min, &max, &step)
                        let passed = write == 0 && read == 0 && readback == dpi
                        failed = failed || !passed
                        print("DPI same-value write/readback: \(passed ? "PASS" : "FAIL")")
                    }
                    if result != 0 && CommandLine.arguments.contains("--verify-dpi-write") { failed = true }
                } else { print("No HID++ device replied."); failed = true }
            } else { print("HID++ interface unavailable (check Input Monitoring)."); failed = true }
        }
        return failed ? 1 : 0
    }
}
