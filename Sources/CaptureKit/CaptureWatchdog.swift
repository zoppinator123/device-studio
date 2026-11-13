import Foundation

/// What the watchdog can report. The session decides what to do about each one.
public enum WatchdogFinding: Equatable, Sendable {
    /// No buffers at all from this channel for `stallSeconds`: device lost, tap died, or the Mac slept.
    case stalled(CaptureChannel)
    /// System audio is delivering only zeros while something is playing. There is no API to ask whether the
    /// system-audio permission was granted; this behaviour is how a denial is detected.
    case systemAudioLooksDenied
    /// Both channels silent for the "are you still recording?" interval.
    case askWhetherToStop
    /// Still silent after the grace period that follows the question.
    case autoStop
    /// Hard cap on recording length.
    case hardCapReached
}

/// Pure bookkeeping: fed buffer facts and the current time, it returns findings. No timers, no audio calls,
/// so every rule is unit-tested. Times are meeting milliseconds from `HostClock`.
public struct CaptureWatchdog {
    public struct Limits: Sendable {
        public var stallMs: Int64 = 3_000
        public var deniedMs: Int64 = 5_000
        public var silenceAskMs: Int64 = 20 * 60_000
        public var silenceGraceMs: Int64 = 5 * 60_000
        public var hardCapMs: Int64 = 8 * 3_600_000
        /// Peak below this counts as silence (16-bit noise floor is about 3e-5).
        public var silencePeak: Float = 1e-4
        public init() {}
    }

    public let limits: Limits
    public let channels: Set<CaptureChannel>
    private var lastBufferMs: [CaptureChannel: Int64] = [:]
    private var lastSoundMs: [CaptureChannel: Int64] = [:]
    private var lastNonZeroMs: [CaptureChannel: Int64] = [:]
    private var reported: Set<String> = []
    private var askedAtMs: Int64?

    public init(channels: Set<CaptureChannel>, limits: Limits = Limits()) {
        self.channels = channels
        self.limits = limits
        for c in channels { lastBufferMs[c] = 0; lastSoundMs[c] = 0; lastNonZeroMs[c] = 0 }
    }

    /// Call for every buffer delivered. `peak` is the largest absolute sample in it.
    public mutating func noteBuffer(_ channel: CaptureChannel, atMs: Int64, peak: Float) {
        lastBufferMs[channel] = atMs
        if peak > 0 { lastNonZeroMs[channel] = atMs }
        if peak >= limits.silencePeak {
            lastSoundMs[channel] = atMs
            askedAtMs = nil
            reported.remove("ask"); reported.remove("auto")
        }
        reported.remove("stall-\(channel.rawValue)")
    }

    /// The user answered "keep recording": the silence timer starts again from now.
    public mutating func keepRecording(atMs: Int64) {
        for c in channels { lastSoundMs[c] = atMs }
        askedAtMs = nil
        reported.remove("ask"); reported.remove("auto")
    }

    /// Call about once a second. Each finding is reported once per occurrence, not on every call.
    public mutating func evaluate(nowMs: Int64, outputDeviceIsRunning: Bool) -> [WatchdogFinding] {
        var out: [WatchdogFinding] = []
        func once(_ key: String, _ finding: WatchdogFinding) {
            if reported.insert(key).inserted { out.append(finding) }
        }
        if nowMs >= limits.hardCapMs { once("cap", .hardCapReached) }
        for c in channels.sorted(by: { $0.rawValue < $1.rawValue }) where nowMs - (lastBufferMs[c] ?? 0) >= limits.stallMs {
            once("stall-\(c.rawValue)", .stalled(c))
        }
        if channels.contains(.system), outputDeviceIsRunning,
           nowMs - (lastBufferMs[.system] ?? 0) < limits.stallMs,          // buffers are arriving
           nowMs - (lastNonZeroMs[.system] ?? 0) >= limits.deniedMs {       // and every one is zeros
            once("denied", .systemAudioLooksDenied)
        } else if (lastNonZeroMs[.system] ?? 0) > 0, nowMs - (lastNonZeroMs[.system] ?? 0) < limits.deniedMs {
            reported.remove("denied")
        }
        let quietSince = channels.map { lastSoundMs[$0] ?? 0 }.max() ?? 0
        if nowMs - quietSince >= limits.silenceAskMs {
            if askedAtMs == nil { askedAtMs = nowMs }
            once("ask", .askWhetherToStop)
            if let asked = askedAtMs, nowMs - asked >= limits.silenceGraceMs { once("auto", .autoStop) }
        }
        return out
    }
}
