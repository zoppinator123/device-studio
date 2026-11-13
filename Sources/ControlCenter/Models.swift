import Foundation
import CoreGraphics

struct Shortcut: Codable, Equatable {
    var keyCode: UInt16
    var modifiers: UInt64
    var label: String
}

enum ActionKind: String, Codable, CaseIterable, Identifiable {
    case passthrough, shortcut, back, forward, missionControl, desktop, cameraPreset, toggleRecording
    var id: String { rawValue }
    var title: String {
        switch self {
        case .passthrough: return "Default behavior"
        case .shortcut: return "Keyboard shortcut"
        case .back: return "Back (⌘[)"
        case .forward: return "Forward (⌘])"
        case .missionControl: return "Mission Control (⌃↑)"
        case .desktop: return "Show desktop (F11)"
        case .cameraPreset: return "Apply camera preset"
        case .toggleRecording: return "Start or stop meeting recording"
        }
    }
}
struct MouseAction: Codable, Equatable {
    var kind: ActionKind = .passthrough
    var shortcut: Shortcut?
    var presetID: UUID?
    var isConfigured: Bool { kind != .passthrough && (kind != .shortcut || shortcut != nil) && (kind != .cameraPreset || presetID != nil) }
}
struct ButtonRule: Codable, Identifiable, Equatable {
    var id = UUID()
    var button: Int = 3
    var action = MouseAction()
    var up = MouseAction()
    var down = MouseAction()
    var left = MouseAction()
    var right = MouseAction()
    var hasGesture: Bool { [up, down, left, right].contains(where: \.isConfigured) }
    var captures: Bool { action.isConfigured || hasGesture }
    func releaseBehavior(dx: Double, dy: Double) -> ReleaseBehavior {
        if hasGesture, let direction = ProfileResolver.gesture(dx: dx, dy: dy) {
            let selected: MouseAction
            switch direction { case "up": selected = up; case "down": selected = down; case "left": selected = left; default: selected = right }
            return selected.isConfigured ? .action(selected) : .suppress
        }
        return action.isConfigured ? .action(action) : .nativeClick
    }
    var label: String {
        switch button { case 2: return "Middle click"; case 3: return "Side button 1"; case 4: return "Side button 2"; default: return "Button \(button + 1)" }
    }
}
enum ReleaseBehavior: Equatable { case nativeClick, action(MouseAction), suppress }
struct MouseProfile: Codable, Identifiable, Equatable {
    var id = UUID()
    var name = "Default"
    var bundleID: String? = nil
    var rules: [ButtonRule] = [ButtonRule(button: 2), ButtonRule(button: 3), ButtonRule(button: 4)]
    var scrollSpeed: Double = 1
    var reverseVertical = false
    var reverseHorizontal = false
    var includeContinuousScroll = false
}
struct CameraPreset: Codable, Identifiable, Equatable {
    var id = UUID()
    var name: String
    var deviceID: String
    var values: [String: Int]
}
struct Settings: Codable, Equatable {
    var schemaVersion = 1
    var profiles = [MouseProfile()]
    var cameraPresets: [CameraPreset] = []
    var granolaThumb = GranolaThumbSettings()
    var setup = SetupProgress()
    var meetings = MeetingSettings()
    init() {}
    private enum CodingKeys: String, CodingKey { case schemaVersion, profiles, cameraPresets, granolaThumb, setup, meetings }
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try values.decode(Int.self, forKey: .schemaVersion)
        profiles = try values.decode([MouseProfile].self, forKey: .profiles)
        cameraPresets = try values.decode([CameraPreset].self, forKey: .cameraPresets)
        granolaThumb = try values.decodeIfPresent(GranolaThumbSettings.self, forKey: .granolaThumb) ?? GranolaThumbSettings()
        setup = try values.decodeIfPresent(SetupProgress.self, forKey: .setup) ?? SetupProgress()
        meetings = try values.decodeIfPresent(MeetingSettings.self, forKey: .meetings) ?? MeetingSettings()
    }
}

/// Meeting recording preferences. Recordings themselves are not settings; they live in their own encrypted
/// folder (see MeetingRecorder).
struct MeetingSettings: Codable, Equatable {
    var mode = MeetingMode.call
    var echo = MeetingEchoMode.off
    /// The one-time explanation of what is recorded has been read and accepted.
    var explainerAccepted = false
    init() {}
    private enum CodingKeys: String, CodingKey { case mode, echo, explainerAccepted }
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        mode = (try? values.decode(MeetingMode.self, forKey: .mode)) ?? .call
        echo = (try? values.decode(MeetingEchoMode.self, forKey: .echo)) ?? .off
        explainerAccepted = (try? values.decode(Bool.self, forKey: .explainerAccepted)) ?? false
    }
}

enum MeetingMode: String, Codable, CaseIterable, Identifiable {
    case call, inPerson
    var id: String { rawValue }
    var title: String { self == .call ? "Call: my microphone and what my Mac plays" : "In person: microphone only" }
}

enum MeetingEchoMode: String, Codable, CaseIterable, Identifiable {
    case off, whenOnSpeakers, always
    var id: String { rawValue }
    var title: String {
        switch self {
        case .off: return "Off"
        case .whenOnSpeakers: return "When not using headphones"
        case .always: return "Always"
        }
    }
}

struct GranolaThumbSettings: Codable, Equatable {
    var enabled = false
    // Logitech's haptic thumb panel; the older gesture thumb button is 0x00c3.
    var controlID = 0x01a0
    var modifier = DictationModifier.leftOption
    init(enabled: Bool = false, controlID: Int = 0x01a0, modifier: DictationModifier = .leftOption) {
        self.enabled = enabled; self.controlID = controlID; self.modifier = modifier
    }
    private enum CodingKeys: String, CodingKey { case enabled, controlID, modifier }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        enabled = try c.decode(Bool.self, forKey: .enabled)
        controlID = try c.decode(Int.self, forKey: .controlID)
        modifier = try c.decodeIfPresent(DictationModifier.self, forKey: .modifier) ?? .leftOption
    }
}
enum DictationModifier: String, Codable, CaseIterable, Identifiable {
    case leftOption, leftCommand
    var id: String { rawValue }
    var title: String { self == .leftOption ? "⌥ Option / Alt" : "⌘ Command" }
    var keyCode: CGKeyCode { self == .leftOption ? 58 : 55 }
    var oppositeKeyCode: CGKeyCode { self == .leftOption ? 61 : 54 }
    var mask: CGEventFlags { self == .leftOption ? .maskAlternate : .maskCommand }
    var leftDeviceMask: UInt64 { self == .leftOption ? 0x20 : 0x8 }
}
enum KeyHoldTransition: Equatable { case press, release }
struct KeyHoldState {
    private(set) var held = false
    mutating func update(pressed: Bool) -> KeyHoldTransition? {
        guard held != pressed else { return nil }
        held = pressed
        return pressed ? .press : .release
    }
}

enum ProfileResolver {
    static func resolve(_ profiles: [MouseProfile], bundleID: String?) -> MouseProfile {
        if let bundleID, let profile = profiles.first(where: { $0.bundleID == bundleID }) { return profile }
        return profiles.first(where: { $0.bundleID == nil }) ?? MouseProfile()
    }
    static func gesture(dx: Double, dy: Double, threshold: Double = 45) -> String? {
        guard max(abs(dx), abs(dy)) >= threshold else { return nil }
        if abs(dx) > abs(dy) { return dx > 0 ? "right" : "left" }
        return dy > 0 ? "down" : "up"
    }
}

final class SettingsStore {
    let url: URL
    init(url: URL? = nil) {
        self.url = url ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("DeviceStudio/settings.json")
    }
    func load() throws -> Settings {
        guard FileManager.default.fileExists(atPath: url.path) else { return Settings() }
        let settings = try JSONDecoder().decode(Settings.self, from: Data(contentsOf: url))
        guard settings.schemaVersion == 1, [0x01a0, 0x00c3].contains(settings.granolaThumb.controlID), settings.profiles.contains(where: { $0.bundleID == nil }),
              settings.profiles.allSatisfy({ $0.scrollSpeed.isFinite && (0.2...4).contains($0.scrollSpeed) &&
                  Set($0.rules.map(\.button)).count == $0.rules.count && $0.rules.allSatisfy({ (2...31).contains($0.button) }) }) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        return settings
    }
    func save(_ settings: Settings) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(settings).write(to: url, options: .atomic)
    }
}
