import Foundation
import CoreGraphics

// Compiles against the production Models.swift without needing Xcode's XCTest.
@main struct ControlCenterChecks {
    static func main() throws {
        let fallback = MouseProfile()
        let browser = MouseProfile(name: "Browser", bundleID: "com.test.browser", scrollSpeed: 2)
        precondition(ProfileResolver.resolve([fallback, browser], bundleID: "com.test.browser") == browser)
        precondition(ProfileResolver.resolve([fallback, browser], bundleID: "com.test.editor") == fallback)
        precondition(ProfileResolver.resolve([fallback, browser], bundleID: nil) == fallback)
        print("PASS: per-app profile resolution and fallback")

        precondition(ProfileResolver.gesture(dx: 10, dy: -44) == nil)
        precondition(ProfileResolver.gesture(dx: 80, dy: -60) == "right")
        precondition(ProfileResolver.gesture(dx: -70, dy: 5) == "left")
        precondition(ProfileResolver.gesture(dx: 5, dy: -45) == "up")
        precondition(ProfileResolver.gesture(dx: 2, dy: 90) == "down")
        print("PASS: gesture thresholds and dominant direction")

        var rule = ButtonRule(); rule.action.kind = .shortcut
        precondition(!rule.captures)
        rule.action.shortcut = Shortcut(keyCode: 0, modifiers: 0, label: "A")
        precondition(rule.captures)
        rule.action = MouseAction(); rule.up.kind = .cameraPreset
        precondition(!rule.captures)
        rule.up.presetID = UUID(); precondition(rule.captures)
        print("PASS: incomplete actions leave buttons untouched")

        rule = ButtonRule(); rule.up = MouseAction(kind: .back)
        precondition(rule.releaseBehavior(dx: 0, dy: 0) == .nativeClick)
        precondition(rule.releaseBehavior(dx: 0, dy: -80) == .action(MouseAction(kind: .back)))
        precondition(rule.releaseBehavior(dx: 0, dy: 80) == .suppress)
        rule.action = MouseAction(kind: .forward)
        precondition(rule.releaseBehavior(dx: 0, dy: 0) == .action(MouseAction(kind: .forward)))
        print("PASS: gesture buttons preserve native short clicks and resolve assigned directions")

        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = SettingsStore(url: directory.appendingPathComponent("nested/settings.json"))
        var settings = Settings(); settings.profiles[0].rules[0].up = MouseAction(kind: .back)
        settings.profiles.append(MouseProfile(name: "Editor", bundleID: "com.test.editor", reverseHorizontal: true))
        settings.cameraPresets.append(CameraPreset(name: "Desk", deviceID: "camera-one", values: ["3:2": 8]))
        try store.save(settings)
        let loaded = try store.load(); precondition(loaded == settings)
        print("PASS: profiles, gestures, and camera presets persist")

        let original = Data("broken json".utf8); try original.write(to: store.url)
        do { _ = try store.load(); fatalError("Corrupt settings must fail") } catch {}
        let preserved = try Data(contentsOf: store.url); precondition(preserved == original)
        print("PASS: corrupt settings are preserved")

        settings = Settings(); settings.profiles[0].rules[0].button = 0
        try store.save(settings)
        do { _ = try store.load(); fatalError("Primary button must be rejected") } catch {}
        settings = Settings(); settings.profiles[0].rules[1].button = 2
        try store.save(settings)
        do { _ = try store.load(); fatalError("Duplicate buttons must be rejected") } catch {}
        settings = Settings(); settings.profiles[0].scrollSpeed = 100
        try store.save(settings)
        do { _ = try store.load(); fatalError("Invalid wheel speed must be rejected") } catch {}
        print("PASS: unsafe buttons, duplicate rules, and invalid wheel speed rejected")

        var hold = KeyHoldState()
        precondition(hold.update(pressed: false) == nil)
        precondition(hold.update(pressed: true) == .press)
        precondition(hold.update(pressed: true) == nil)
        precondition(hold.update(pressed: false) == .release)
        precondition(hold.update(pressed: false) == nil)
        precondition(!hold.held)
        print("PASS: thumb hold emits one press and one release, including cancellation")

        settings = Settings(); settings.granolaThumb = GranolaThumbSettings(enabled: true, controlID: 0x01a0)
        try store.save(settings)
        let granolaLoaded = try store.load(); precondition(granolaLoaded == settings)
        var legacy = try JSONSerialization.jsonObject(with: Data(contentsOf: store.url)) as! [String: Any]
        legacy.removeValue(forKey: "granolaThumb")
        try JSONSerialization.data(withJSONObject: legacy).write(to: store.url)
        let migrated = try store.load(); precondition(migrated.granolaThumb == GranolaThumbSettings())
        settings.granolaThumb.controlID = 0x0050 // Never divert a primary mouse button.
        try store.save(settings)
        do { _ = try store.load(); fatalError("A primary button must not be accepted as the thumb control") } catch {}
        print("PASS: Granola settings persist, older settings load, and primary buttons are rejected")
        for (modifier, code, mask, deviceBit) in [
            (DictationModifier.leftOption, UInt16(58), CGEventFlags.maskAlternate, UInt64(0x20)),
            (DictationModifier.leftCommand, UInt16(55), CGEventFlags.maskCommand, UInt64(0x8))
        ] {
            let down = GranolaKeyEvent.make(pressed: true, modifier: modifier, currentFlags: .maskControl, oppositeKeyHeld: false)!
            precondition(down.type == .flagsChanged)
            precondition(down.getIntegerValueField(.keyboardEventKeycode) == code)
            precondition(down.flags.contains([.maskControl, mask]))
            precondition(down.flags.rawValue & deviceBit != 0)
            let up = GranolaKeyEvent.make(pressed: false, modifier: modifier, currentFlags: down.flags, oppositeKeyHeld: false)!
            precondition(up.type == .flagsChanged)
            precondition(up.getIntegerValueField(.keyboardEventKeycode) == code)
            precondition(!up.flags.contains(mask) && up.flags.contains(.maskControl))
            precondition(up.flags.rawValue & deviceBit == 0)
            let rightHeld = GranolaKeyEvent.make(pressed: false, modifier: modifier, currentFlags: down.flags, oppositeKeyHeld: true)!
            precondition(rightHeld.flags.contains(mask))
            precondition(down.getIntegerValueField(.eventSourceUserData) == GranolaKeyEvent.marker)
        }
        precondition(GranolaThumbSettings().modifier == .leftOption)
        print("PASS: configured Option and Command keys press/release correctly and preserve other modifiers (not posted to macOS)")
        var setup = SetupProgress()
        let noDevices = SetupFacts()
        precondition(SetupPolicy.blocker(step: .devices, progress: setup, facts: noDevices) != nil)
        precondition(!setup.isComplete(binding: GranolaThumbSettings()))
        setup.goals = SetupGoals(granola: false, mouseMappings: false, camera: false)
        precondition(SetupPolicy.blocker(step: .welcome, progress: setup, facts: noDevices) != nil)
        print("PASS: fresh setup does not skip device checks or allow an empty goal selection")

        setup = SetupProgress(); setup.shortcutConfirmed = true
        let connected = SetupFacts(mouseConnected: true, supportedThumbControls: [0x1a0], controlAccess: true, hardwareAccess: true, granolaInstalled: true)
        let hardwareOnly = SetupEvidence(thumbPressed: true, thumbReleased: true)
        precondition(SetupPolicy.blocker(step: .test, progress: setup, facts: connected, evidence: hardwareOnly) != nil)
        let voiceConfirmed = SetupEvidence(thumbPressed: true, thumbReleased: true, dictationConfirmed: true)
        precondition(SetupPolicy.blocker(step: .test, progress: setup, facts: connected, evidence: voiceConfirmed) == nil)
        var denied = connected; denied.controlAccess = false
        precondition(SetupPolicy.blocker(step: .test, progress: setup, facts: denied, evidence: voiceConfirmed) != nil)
        var disconnected = connected; disconnected.mouseConnected = false
        precondition(SetupPolicy.blocker(step: .test, progress: setup, facts: disconnected, evidence: voiceConfirmed) != nil)
        setup.shortcutConfirmed = false
        precondition(SetupPolicy.blocker(step: .test, progress: setup, facts: connected, evidence: voiceConfirmed) != nil)
        print("PASS: finishing requires real input, explicit dictation confirmation, permissions, a connection, and a matched shortcut")

        setup = SetupProgress(); setup.goals = SetupGoals(granola: false, mouseMappings: false, camera: true)
        precondition(!setup.steps.contains(.shortcut))
        let cameraFacts = SetupFacts(cameraConnected: true, cameraControlsAvailable: true, cameraAccess: true)
        precondition(SetupPolicy.blocker(step: .test, progress: setup, facts: cameraFacts, evidence: SetupEvidence(cameraVerified: true)) == nil)
        setup.controlsOnly = true
        var noPreview = cameraFacts; noPreview.cameraAccess = false
        precondition(SetupPolicy.blocker(step: .test, progress: setup, facts: noPreview, evidence: SetupEvidence(cameraVerified: true)) == nil)
        noPreview.cameraControlsAvailable = false
        precondition(SetupPolicy.blocker(step: .permissions, progress: setup, facts: noPreview) != nil)
        setup.goals = SetupGoals(granola: false, mouseMappings: true, camera: false)
        precondition(SetupPolicy.blocker(step: .test, progress: setup, facts: connected, evidence: SetupEvidence(buttonDetected: true, wheelDetected: true)) == nil)
        print("PASS: optional features skip unrelated steps, while preview-only cameras cannot claim hardware-only setup")

        settings = Settings(); settings.setup.move(to: .shortcut); settings.setup.shortcutConfirmed = true
        try store.save(settings)
        let resumed = try store.load(); precondition(resumed.setup.step == .shortcut && resumed.setup.furthestStep == .shortcut)
        settings.setup.completedAt = Date(); settings.setup.verifiedBinding = settings.granolaThumb
        precondition(settings.setup.isComplete(binding: settings.granolaThumb))
        var changedBinding = settings.granolaThumb; changedBinding.modifier = .leftCommand
        precondition(!settings.setup.isComplete(binding: changedBinding))
        settings.setup.restart()
        precondition(settings.setup.step == .welcome && settings.setup.completedAt == nil && !settings.setup.shortcutConfirmed)
        try store.save(settings)
        var oldFormat = try JSONSerialization.jsonObject(with: Data(contentsOf: store.url)) as! [String: Any]
        oldFormat.removeValue(forKey: "setup")
        try JSONSerialization.data(withJSONObject: oldFormat).write(to: store.url)
        let firstWizardRun = try store.load()
        precondition(firstWizardRun.profiles == settings.profiles && firstWizardRun.granolaThumb == settings.granolaThumb)
        precondition(firstWizardRun.setup.step == .welcome && firstWizardRun.setup.completedAt == nil)
        print("PASS: setup resumes, changed bindings require re-verification, and legacy profiles migrate without losing settings")
        print("All 14 Swift checks passed.")
    }
}
