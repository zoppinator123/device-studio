import Foundation
import CDeviceSupport

// IOHID callbacks and their run loop must stay on one OS thread for the full hold.
final class ThumbButtonMonitor: @unchecked Sendable {
    private let lock = NSLock()
    private static let ownership = NSLock()
    private let finished = DispatchGroup()
    private var cancelled = false
    let onButton: @Sendable (Bool) -> Void
    let onState: @Sendable (Bool, String) -> Void
    init(onButton: @escaping @Sendable (Bool) -> Void, onState: @escaping @Sendable (Bool, String) -> Void) {
        self.onButton = onButton; self.onState = onState
    }
    private var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return cancelled }
    func start(cid: Int) {
        finished.enter()
        let worker = Thread { [self] in
            defer { finished.leave() }
            Self.ownership.lock()
            defer { Self.ownership.unlock() }
            guard !isCancelled else { return }
            guard let mouse = ds_mouse_open() else { onState(false, "Allow Input Monitoring, then reconnect the thumb button."); return }
            defer { ds_mouse_close(mouse) }
            var connected = ds_mouse_probe(mouse) == 0
            // The first request can wake a sleeping wireless mouse without a reply.
            if !connected && !isCancelled { connected = ds_mouse_probe(mouse) == 0 }
            guard connected else { onState(false, "Wake your MX Master and reconnect the thumb button."); return }
            guard !isCancelled else { return }
            let context = Unmanaged.passUnretained(self).toOpaque()
            let result = ds_mouse_begin_button(mouse, Int32(cid), { context, pressed in
                guard let context else { return }
                Unmanaged<ThumbButtonMonitor>.fromOpaque(context).takeUnretainedValue().onButton(pressed != 0)
            }, context)
            guard result == 0 else { onState(false, "Could not capture this thumb button (\(result)). Try the other thumb-button option, or close another mouse utility."); return }
            onState(true, "Ready. Hold the large thumb button to dictate; release it to stop.")
            while !isCancelled {
                if ds_mouse_poll(mouse, 0.05) != 0 { onState(false, "The mouse disconnected. Reconnect the thumb button to resume."); break }
            }
            let restored = ds_mouse_end_button(mouse)
            if restored != 0 { onState(false, "The mouse disconnected before its thumb-button setting could be restored. Reconnect or power-cycle the mouse.") }
        }
        worker.name = "Device Studio thumb button"; worker.start()
    }
    func stop(wait: Bool = false) {
        lock.lock(); cancelled = true; lock.unlock()
        if wait { _ = finished.wait(timeout: .now() + 3) }
    }
}
