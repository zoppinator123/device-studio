import Foundation

enum SetupStep: String, Codable, CaseIterable, Identifiable {
    case welcome, devices, permissions, shortcut, test, complete
    var id: String { rawValue }
    var order: Int { Self.allCases.firstIndex(of: self)! }
    var title: String {
        switch self {
        case .welcome: return "Choose your setup"
        case .devices: return "Connect your devices"
        case .permissions: return "Allow access"
        case .shortcut: return "Match Granola’s shortcut"
        case .test: return "Try it for real"
        case .complete: return "You’re ready"
        }
    }
}
struct SetupGoals: Codable, Equatable {
    var granola = true
    var mouseMappings = false
    var camera = false
    var hasSelection: Bool { granola || mouseMappings || camera }
    var needsMouseAccess: Bool { granola || mouseMappings }
}
struct SetupProgress: Codable, Equatable {
    var goals = SetupGoals()
    var step = SetupStep.welcome
    var furthestStep = SetupStep.welcome
    var shortcutConfirmed = false
    var controlsOnly = false
    var completedAt: Date?
    var verifiedBinding: GranolaThumbSettings?
    var steps: [SetupStep] { SetupStep.allCases.filter { $0 != .shortcut || goals.granola } }
    func isComplete(binding: GranolaThumbSettings) -> Bool {
        completedAt != nil && goals.hasSelection && (!goals.granola || verifiedBinding == binding)
    }
    mutating func move(to destination: SetupStep) {
        step = destination
        if destination.order > furthestStep.order { furthestStep = destination }
    }
    mutating func restart() {
        step = .welcome; furthestStep = .welcome; completedAt = nil
        shortcutConfirmed = false; verifiedBinding = nil
    }
}
struct SetupFacts {
    var mouseConnected = false
    var supportedThumbControls: [Int] = []
    var cameraConnected = false
    var cameraControlsAvailable = false
    var controlAccess = false
    var hardwareAccess = false
    var cameraAccess = false
    var granolaInstalled = false
}
struct SetupEvidence {
    var thumbPressed = false
    var thumbReleased = false
    var dictationConfirmed = false
    var buttonDetected = false
    var wheelDetected = false
    var cameraVerified = false
    func isComplete(for goals: SetupGoals) -> Bool {
        goals.hasSelection && (!goals.granola || (thumbPressed && thumbReleased && dictationConfirmed)) &&
        (!goals.mouseMappings || (buttonDetected && wheelDetected)) &&
        (!goals.camera || cameraVerified)
    }
}
enum SetupPolicy {
    static func blocker(step: SetupStep, progress: SetupProgress, facts: SetupFacts, evidence: SetupEvidence = SetupEvidence()) -> String? {
        let goals = progress.goals
        guard goals.hasSelection else { return "Choose at least one feature to set up." }
        switch step {
        case .welcome, .complete: return nil
        case .devices:
            if goals.granola && !facts.mouseConnected { return "Connect and wake your Logitech mouse, then check again." }
            if goals.granola && facts.supportedThumbControls.isEmpty { return "This connection has no supported thumb control. Try a receiver or set up another feature." }
            if goals.camera && !facts.cameraConnected { return "Connect a camera, or go back and leave camera setup for later." }
        case .permissions:
            if goals.needsMouseAccess && !facts.controlAccess { return "Allow Device Studio to control input in System Settings." }
            if goals.granola && !facts.hardwareAccess { return "Allow Input Monitoring, reopen Device Studio, and retry the connection." }
            if goals.camera && progress.controlsOnly && !facts.cameraControlsAvailable { return "Hardware-only setup needs a camera with supported image controls." }
            if goals.camera && !progress.controlsOnly && !facts.cameraAccess { return "Allow Camera access for preview, or choose hardware controls only." }
        case .shortcut:
            if !facts.granolaInstalled { return "Install Granola, then return here and check again." }
            if !progress.shortcutConfirmed { return "Confirm the actual Hold to talk shortcut shown in Granola’s settings." }
        case .test:
            // Recheck earlier requirements: back navigation and disconnected
            // hardware must never let a stale test mark setup as complete.
            for earlier in [SetupStep.devices, .permissions] + (goals.granola ? [.shortcut] : []) {
                if let problem = blocker(step: earlier, progress: progress, facts: facts) { return problem }
            }
            if !evidence.isComplete(for: goals) { return "Complete the live checks below before finishing setup." }
        }
        return nil
    }
}
