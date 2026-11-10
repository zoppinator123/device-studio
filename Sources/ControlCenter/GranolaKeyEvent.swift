import CoreGraphics

enum GranolaKeyEvent {
    static let marker: Int64 = 0x4453545544494f
    static func make(pressed: Bool, modifier: DictationModifier, currentFlags: CGEventFlags, oppositeKeyHeld: Bool) -> CGEvent? {
        guard let source = CGEventSource(stateID: .privateState),
              let event = CGEvent(keyboardEventSource: source, virtualKey: modifier.keyCode, keyDown: pressed) else { return nil }
        var flags = currentFlags
        let leftModifier = CGEventFlags(rawValue: modifier.mask.rawValue | modifier.leftDeviceMask)
        if pressed { flags.formUnion(leftModifier) }
        else {
            flags.subtract(leftModifier)
            if oppositeKeyHeld { flags.insert(modifier.mask) }
        }
        event.type = .flagsChanged
        event.flags = flags
        event.setIntegerValueField(.eventSourceUserData, value: marker)
        return event
    }
}
