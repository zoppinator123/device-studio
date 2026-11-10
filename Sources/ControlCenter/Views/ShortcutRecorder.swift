import AppKit
import SwiftUI

/// A button that records the next key combination pressed while it has focus.
struct ShortcutRecorder: NSViewRepresentable {
    @Binding var shortcut: Shortcut?

    func makeNSView(context: Context) -> RecorderButton {
        let view = RecorderButton()
        view.onRecord = { shortcut = $0 }
        return view
    }

    func updateNSView(_ view: RecorderButton, context: Context) {
        view.recordedLabel = shortcut?.label ?? RecorderButton.placeholder
        if !view.recording { view.title = view.recordedLabel }
        view.onRecord = { shortcut = $0 }
    }
}

final class RecorderButton: NSButton {
    static let placeholder = "Record Shortcut"
    private static let escapeKeyCode: UInt16 = 53
    private static let keyNames: [UInt16: String] = [
        36: "↩", 48: "⇥", 49: "Space", 51: "⌫",
        123: "←", 124: "→", 125: "↓", 126: "↑",
        122: "F1", 120: "F2", 99: "F3", 118: "F4", 96: "F5", 97: "F6",
        98: "F7", 100: "F8", 101: "F9", 109: "F10", 103: "F11", 111: "F12"
    ]

    var onRecord: ((Shortcut) -> Void)?
    var recording = false
    var recordedLabel = RecorderButton.placeholder

    override var acceptsFirstResponder: Bool { true }

    init() {
        super.init(frame: .zero)
        bezelStyle = .rounded
        target = self
        action = #selector(beginRecording)
        toolTip = "Click, then press the shortcut. Esc cancels."
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    @objc private func beginRecording() {
        recording = true
        title = "Press Keys…"
        window?.makeFirstResponder(self)
    }

    private func endRecording() {
        recording = false
        title = recordedLabel
    }

    override func resignFirstResponder() -> Bool {
        endRecording()
        return super.resignFirstResponder()
    }

    // Shortcuts that include ⌘ arrive here rather than through keyDown.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard recording, event.type == .keyDown else { return super.performKeyEquivalent(with: event) }
        keyDown(with: event)
        return true
    }

    override func keyDown(with event: NSEvent) {
        guard recording else { super.keyDown(with: event); return }
        guard event.keyCode != Self.escapeKeyCode else { endRecording(); return }

        let flags = event.modifierFlags.intersection([.command, .option, .control, .shift])
        var label = ""
        if flags.contains(.control) { label += "⌃" }
        if flags.contains(.option) { label += "⌥" }
        if flags.contains(.shift) { label += "⇧" }
        if flags.contains(.command) { label += "⌘" }
        label += Self.keyNames[event.keyCode] ?? event.charactersIgnoringModifiers?.uppercased() ?? "Key \(event.keyCode)"

        recordedLabel = label
        endRecording()
        onRecord?(Shortcut(keyCode: event.keyCode, modifiers: UInt64(flags.rawValue), label: label))
    }
}
