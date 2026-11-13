import AVFoundation
import Foundation

/// One recording: microphone and system audio as two separate mono channels on one clock, spooled encrypted
/// in 5-second segments. The two streams are never mixed.
///
/// The host app owns the UI: the permission explainer, the always-visible recording indicator, and what to
/// say for each event. This type reports; it does not present anything.
public final class CaptureSession {
    public struct Configuration: Sendable {
        /// `[.microphone]` for an in-person meeting; both for a call.
        public var sources: Set<CaptureChannel> = [.microphone, .system]
        /// Refuse to start with less free space than this (about 230 MB per hour is written).
        public var minimumFreeBytes: Int64 = 2_000_000_000
        public var echoCancellation: EchoCancellation = .off
        /// Write audio to the encrypted spool. Off for transcript-only meetings: segments are handed to the
        /// host (for live transcription) and never touch the disk.
        public var spoolAudio = true
        /// Segment length. Short segments (1 s) keep live transcription close behind the speaker.
        public var segmentSeconds: Double = 5
        public var limits = CaptureWatchdog.Limits()
        public init() {}
    }

    /// How system audio is being captured.
    public enum SystemAudioPath: String, Sendable {
        case processTap = "Core Audio tap"
        case screenCaptureKit = "ScreenCaptureKit (fallback)"
    }

    public enum Event: Sendable {
        /// A segment is sealed and durable on disk. Feed it to transcription.
        case segment(AudioSegment)
        case finding(WatchdogFinding)
        /// System audio is being captured, and how.
        case systemAudioStarted(SystemAudioPath)
        /// System audio could not be opened by either path. Recording continues with the microphone only.
        case systemAudioUnavailable(CaptureError)
        /// A source was reopened after the default device changed; the transcript will show a short gap.
        case sourceRestarted(CaptureChannel)
        /// A source could not be reopened after a device change.
        case sourceLost(CaptureChannel)
        /// Echo cancellation state for the microphone channel at start or after a device change.
        case echoCancellation(enabled: Bool, route: OutputRoute)
        /// A segment could not be written. Audio is never dropped silently: the host must tell the user.
        case spoolWriteFailed(CaptureChannel, sequence: Int)
        case stopped(Summary)
    }

    public struct Summary: Equatable, Sendable {
        public var segments: [CaptureChannel: Int] = [:]
        public var endMs: Int64 = 0
        public var activeSources: Set<CaptureChannel> = []
    }

    public var isRecording: Bool { control.sync { recording } }
    public private(set) var clock: HostClock?

    private let spool: AudioSpool
    private let configuration: Configuration
    private let onEvent: (Event) -> Void
    /// Starting, stopping and reopening sources happen here, one at a time.
    private let control = DispatchQueue(label: "com.jackzoppa.devicestudio.capture.control")
    /// Segments, the spool, the watchdog and events happen here, in order.
    private let work = DispatchQueue(label: "com.jackzoppa.devicestudio.capture.work")
    private let microphone = MicrophoneCapture()
    private let systemTap = SystemAudioTap()
    private let systemFallback = SystemAudioFallback()
    private var systemPath: SystemAudioPath?
    private var recording = false
    private var activeSources: Set<CaptureChannel> = []
    private var lastReopen: [CaptureChannel: Date] = [:]
    // One per source, each touched only by that source's audio thread (a shared dictionary would race).
    private var microphoneResampler: Resampler?
    private var systemResampler: Resampler?
    private var assemblers: [CaptureChannel: SegmentAssembler] = [:]
    private var watchdog: CaptureWatchdog?
    private var timer: DispatchSourceTimer?
    private var activity: NSObjectProtocol?
    private var deviceMonitor: DefaultDeviceMonitor?
    private var summary = Summary()

    /// `onEvent` is called on a private serial queue.
    public init(spool: AudioSpool, configuration: Configuration = Configuration(), onEvent: @escaping (Event) -> Void) {
        self.spool = spool
        self.configuration = configuration
        self.onEvent = onEvent
    }

    public static var microphoneAuthorization: AVAuthorizationStatus { MicrophoneCapture.authorization }

    /// Ask for the microphone. macOS shows its prompt once; afterwards this just reports the stored answer.
    public static func requestMicrophoneAccess(_ completion: @escaping @Sendable (Bool) -> Void) {
        AVCaptureDevice.requestAccess(for: .audio, completionHandler: completion)
    }

    /// Start recording. A denied microphone blocks a recording that needs it; a system-audio
    /// failure does not, and is reported as an event instead.
    public func start() throws {
        try control.sync {
            guard !recording else { throw CaptureError.alreadyRunning }
            let free = (try? spool.directory.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]))?
                .volumeAvailableCapacityForImportantUsage ?? Int64.max
            guard free >= configuration.minimumFreeBytes else { throw CaptureError.notEnoughDiskSpace }

            clock = HostClock(startHostTime: HostClock.now())
            var active: Set<CaptureChannel> = []
            if configuration.sources.contains(.microphone) {
                try startMicrophone()
                active.insert(.microphone)
            }
            if configuration.sources.contains(.system) {
                if startSystemAudio() {
                    active.insert(.system)
                } else if active.isEmpty {
                    throw CaptureError.tapUnavailable(-1)          // nothing else to record
                }
            }
            work.sync {
                summary = Summary()
                for channel in active {
                    assemblers[channel] = SegmentAssembler(channel: channel, segmentSeconds: configuration.segmentSeconds)
                }
                watchdog = CaptureWatchdog(channels: active, limits: configuration.limits)
                summary.activeSources = active
            }
            // The Mac must not idle-sleep in the middle of a meeting.
            activity = ProcessInfo.processInfo.beginActivity(options: [.idleSystemSleepDisabled, .userInitiated],
                                                             reason: "Recording a meeting")
            deviceMonitor = DefaultDeviceMonitor(queue: control,
                                                 onInputChange: { [weak self] in self?.reopen(.microphone) },
                                                 onOutputChange: { [weak self] in self?.reopen(.system) })
            let timer = DispatchSource.makeTimerSource(queue: work)
            timer.schedule(deadline: .now() + 1, repeating: 1)
            timer.setEventHandler { [weak self] in self?.tick() }
            timer.resume()
            self.timer = timer
            activeSources = active
            lastReopen = [:]
            recording = true
        }
    }

    /// Stop, flush what is buffered, and report the summary. Safe to call when not recording.
    public func stop() {
        control.sync {
            guard recording else { return }
            recording = false
            deviceMonitor?.cancel(); deviceMonitor = nil
            microphone.stop()
            stopSystemAudio()
            timer?.cancel(); timer = nil
            if let activity { ProcessInfo.processInfo.endActivity(activity) }
            activity = nil
            work.sync {
                for channel in CaptureChannel.allCases {
                    if let last = assemblers[channel]?.flush() { store(last) }
                }
                assemblers = [:]; watchdog = nil
                microphoneResampler = nil; systemResampler = nil
                if let clock { summary.endMs = max(summary.endMs, clock.milliseconds(for: HostClock.now())) }
                onEvent(.stopped(summary))
            }
        }
    }

    /// The user answered "keep recording" to the long-silence question.
    public func keepRecording() {
        work.async { [self] in
            guard let clock else { return }
            watchdog?.keepRecording(atMs: clock.milliseconds(for: HostClock.now()))
        }
    }

    // MARK: Sources (control queue)

    private func startMicrophone() throws {
        let route = OutputRoute.current()
        let wantEcho = configuration.echoCancellation.enabled(for: route)
        microphone.onConfigurationChange = { [weak self] in self?.control.async { self?.reopen(.microphone) } }
        try microphone.start(voiceProcessing: wantEcho) { [weak self] buffer, hostTime in
            self?.receive(.microphone, buffer, hostTime)
        }
        let enabled = microphone.voiceProcessing
        work.async { self.onEvent(.echoCancellation(enabled: enabled, route: route)) }
    }

    /// Core Audio tap first; ScreenCaptureKit only if the tap cannot be created. Returns whether either works.
    private func startSystemAudio() -> Bool {
        let handler: (AVAudioPCMBuffer, UInt64) -> Void = { [weak self] buffer, hostTime in
            self?.receive(.system, buffer, hostTime)
        }
        do {
            try systemTap.start(handler: handler)
            systemPath = .processTap
        } catch let tapError as CaptureError {
            do {
                systemFallback.onStop = { [weak self] _ in self?.control.async { self?.reopen(.system) } }
                try systemFallback.start(handler: handler)
                systemPath = .screenCaptureKit
            } catch {
                systemPath = nil
                work.async { self.onEvent(.systemAudioUnavailable(tapError)) }
                return false
            }
        } catch {
            return false
        }
        let path = systemPath!
        work.async { self.onEvent(.systemAudioStarted(path)) }
        return true
    }

    private func stopSystemAudio() {
        switch systemPath {
        case .processTap: systemTap.stop()
        case .screenCaptureKit: systemFallback.stop()
        case nil: break
        }
        systemPath = nil
    }

    /// Reopen one source after the default device changed. The segment assembler sees the jump in
    /// host time and starts a new segment, so the change shows as a gap rather than shifted audio.
    private func reopen(_ channel: CaptureChannel) {
        guard recording, activeSources.contains(channel) else { return }
        // A device change can arrive twice (the system notice and the engine's own); reopening also changes
        // the engine configuration. One reopen per channel per two seconds avoids a restart loop.
        if let last = lastReopen[channel], Date().timeIntervalSince(last) < 2 { return }
        lastReopen[channel] = Date()
        switch channel {
        case .microphone:
            microphone.stop()
            do {
                try startMicrophone()
                work.async { self.onEvent(.sourceRestarted(.microphone)) }
            } catch {
                work.async { self.onEvent(.sourceLost(.microphone)) }
            }
        case .system:
            stopSystemAudio()
            let ok = startSystemAudio()
            work.async { self.onEvent(ok ? .sourceRestarted(.system) : .sourceLost(.system)) }
        }
    }

    // MARK: Audio threads

    /// Called on the source's audio thread. The buffer is only valid until this returns, so it is converted
    /// here; everything after that happens on the work queue.
    private func receive(_ channel: CaptureChannel, _ buffer: AVAudioPCMBuffer, _ hostTime: UInt64) {
        guard let clock else { return }
        let resampler: Resampler
        let existing = channel == .microphone ? microphoneResampler : systemResampler
        if let existing, existing.inputFormat == buffer.format {
            resampler = existing
        } else {
            // First buffer, or the device changed format mid-meeting.
            guard let fresh = Resampler(inputFormat: buffer.format) else { return }
            if channel == .microphone { microphoneResampler = fresh } else { systemResampler = fresh }
            resampler = fresh
        }
        let samples = resampler.convert(buffer)
        guard !samples.isEmpty else { return }
        var peak: Float = 0
        for s in samples { let a = abs(s); if a > peak { peak = a } }
        let atMs = clock.milliseconds(for: hostTime)
        work.async { [self] in
            watchdog?.noteBuffer(channel, atMs: atMs, peak: peak)
            guard let segments = assemblers[channel]?.append(samples, atMs: atMs) else { return }
            segments.forEach(store)
        }
    }

    // MARK: Work queue

    private func store(_ segment: AudioSegment) {
        do {
            if configuration.spoolAudio { try spool.append(segment) }
            summary.segments[segment.channel, default: 0] += 1
            summary.endMs = max(summary.endMs, segment.startMs + segment.durationMs)
            onEvent(.segment(segment))
        } catch {
            onEvent(.spoolWriteFailed(segment.channel, sequence: segment.sequence))
        }
    }

    private func tick() {
        guard let clock, var dog = watchdog else { return }
        let findings = dog.evaluate(nowMs: clock.milliseconds(for: HostClock.now()),
                                    outputDeviceIsRunning: SystemAudioTap.outputDeviceIsRunning())
        watchdog = dog
        for finding in findings { onEvent(.finding(finding)) }
        if findings.contains(.autoStop) || findings.contains(.hardCapReached) {
            DispatchQueue.global().async { self.stop() }
        }
    }
}
