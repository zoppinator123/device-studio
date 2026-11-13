import AppKit
import AVFoundation
import CaptureKit
import Combine
import Foundation

/// One saved recording, as listed on the Meetings page. Only ids, times and counts are kept here in clear;
/// the audio is in the meeting's encrypted spool.
struct MeetingRecord: Codable, Identifiable, Equatable {
    enum Status: String, Codable {
        case recording      // in progress, or the app stopped before it could finish
        case recorded       // stopped normally
        case interrupted    // recovered after the app or Mac stopped mid-recording
        case unreadable     // its key is gone; the audio cannot be opened
    }
    var id: String
    var startedAt: Date
    var endedAt: Date?
    var sources: [String]
    var durationSeconds: Int = 0
    var microphoneSegments: Int = 0
    var systemSegments: Int = 0
    var damagedSegments: Int = 0
    var status: Status = .recording
}

/// A message on the Meetings page.
struct MeetingNotice: Identifiable, Equatable {
    enum Kind: Equatable { case info, warning, openPrivacySettings, recordSystemOnly }
    let id = UUID()
    var text: String
    var kind: Kind
}

/// Drives CaptureKit for the Meetings page, the menu bar and the mouse action.
@MainActor final class MeetingRecorder: ObservableObject {
    @Published private(set) var isRecording = false
    @Published private(set) var startedAt: Date?
    @Published private(set) var elapsed: TimeInterval = 0
    @Published private(set) var meetings: [MeetingRecord] = []
    @Published private(set) var notices: [MeetingNotice] = []
    @Published private(set) var systemAudioPath: String?
    @Published private(set) var echoState: String?
    @Published var askWhetherToStop = false
    @Published var showExplainer = false

    let root: URL
    private let keys = MeetingKeyStore(service: "com.jackzoppa.devicestudio.meeting-key")
    private var session: CaptureSession?
    private var current: MeetingRecord?
    private var ticker: AnyCancellable?

    init(root: URL) {
        self.root = root
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.path)
        var values = URLResourceValues(); values.isExcludedFromBackup = true
        var r = root; try? r.setResourceValues(values)
        meetings = loadIndex()
    }

    // MARK: Recording

    func start(settings: MeetingSettings, systemAudioOnly: Bool = false) {
        guard !isRecording else { return }
        notices = []
        let sources: Set<CaptureChannel> = systemAudioOnly ? [.system] : (settings.mode == .call ? [.microphone, .system] : [.microphone])
        if sources.contains(.microphone) {
            switch CaptureSession.microphoneAuthorization {
            case .authorized: break
            case .notDetermined:
                CaptureSession.requestMicrophoneAccess { granted in
                    Task { @MainActor in
                        if granted { self.start(settings: settings) }
                        else { self.microphoneDenied(mode: settings.mode) }
                    }
                }
                return
            default:
                microphoneDenied(mode: settings.mode)
                return
            }
        }
        let id = Self.newMeetingID()
        let record = MeetingRecord(id: id, startedAt: Date(), sources: sources.map(\.rawValue).sorted())
        do {
            // The key and the meeting's entry are saved before the first sample is accepted.
            let key = try keys.create(for: id)
            let spool = try AudioSpool(root: root, meetingID: id, key: key)
            meetings.insert(record, at: 0)
            saveIndex()
            var configuration = CaptureSession.Configuration()
            configuration.sources = sources
            configuration.echoCancellation = EchoCancellation(rawValue: settings.echo.rawValue) ?? .off
            let session = CaptureSession(spool: spool, configuration: configuration) { [weak self] event in
                Task { @MainActor in self?.handle(event) }
            }
            try session.start()
            self.session = session
            current = record
            startedAt = record.startedAt
            elapsed = 0
            isRecording = true
            ticker = Timer.publish(every: 1, on: .main, in: .common).autoconnect().sink { [weak self] _ in
                guard let self, let startedAt = self.startedAt else { return }
                self.elapsed = Date().timeIntervalSince(startedAt)
            }
        } catch {
            try? keys.destroy(for: id)
            try? FileManager.default.removeItem(at: root.appendingPathComponent(id))
            meetings.removeAll { $0.id == id }
            saveIndex()
            notices.append(MeetingNotice(text: Self.describe(error), kind: .warning))
        }
    }

    func stop() {
        guard isRecording, let session else { return }
        session.stop()           // delivers .stopped, which finishes the record
    }

    func keepRecording() {
        askWhetherToStop = false
        session?.keepRecording()
    }

    func dismiss(_ notice: MeetingNotice) { notices.removeAll { $0.id == notice.id } }

    private func microphoneDenied(mode: MeetingMode) {
        notices = [MeetingNotice(text: "Device Studio can’t use the microphone. Allow it in System Settings → Privacy & Security → Microphone.",
                                 kind: .openPrivacySettings)]
        if mode == .call {
            notices.append(MeetingNotice(text: "You can still record only what your Mac plays, without your own voice.",
                                         kind: .recordSystemOnly))
        }
    }

    private func handle(_ event: CaptureSession.Event) {
        switch event {
        case .segment(let segment):
            guard var record = current else { return }
            if segment.channel == .microphone { record.microphoneSegments += 1 } else { record.systemSegments += 1 }
            current = record
        case .systemAudioStarted(let path):
            systemAudioPath = path.rawValue
        case .systemAudioUnavailable:
            notices.append(MeetingNotice(text: "System audio can’t be recorded, so this meeting is recording your microphone only. Other people are captured only if your microphone hears them.",
                                         kind: .openPrivacySettings))
        case .echoCancellation(let enabled, let route):
            let where_ = route == .headphones ? "headphones" : route == .speakers ? "speakers" : "an unknown output"
            echoState = enabled ? "Echo cancellation on (\(where_))" : "Echo cancellation off (\(where_))"
        case .sourceRestarted(let channel):
            notices.append(MeetingNotice(text: "\(Self.name(channel)) switched devices and was reopened. The recording has a short gap there.", kind: .info))
        case .sourceLost(let channel):
            notices.append(MeetingNotice(text: "\(Self.name(channel)) stopped after a device change and could not be reopened.", kind: .warning))
        case .spoolWriteFailed:
            notices.append(MeetingNotice(text: "Audio could not be saved to disk. Check free space; part of this recording is missing.", kind: .warning))
        case .finding(let finding):
            switch finding {
            case .stalled(let channel):
                notices.append(MeetingNotice(text: "\(Self.name(channel)) has stopped delivering audio.", kind: .warning))
            case .systemAudioLooksDenied:
                notices.append(MeetingNotice(text: "Something is playing, but the recording of it is silent. System Audio Recording may be turned off for Device Studio.",
                                             kind: .openPrivacySettings))
            case .askWhetherToStop:
                askWhetherToStop = true
            case .autoStop:
                askWhetherToStop = false
                notices.append(MeetingNotice(text: "Recording stopped after 25 minutes of silence.", kind: .info))
            case .hardCapReached:
                notices.append(MeetingNotice(text: "Recording stopped at the 8-hour limit.", kind: .info))
            }
        case .stopped(let summary):
            if var record = current {
                record.endedAt = Date()
                record.durationSeconds = Int(summary.endMs / 1000)
                record.microphoneSegments = summary.segments[.microphone] ?? 0
                record.systemSegments = summary.segments[.system] ?? 0
                record.status = .recorded
                update(record)
            }
            current = nil
            session = nil
            isRecording = false
            startedAt = nil
            ticker = nil
            askWhetherToStop = false
            systemAudioPath = nil
            echoState = nil
        }
    }

    // MARK: Library

    /// On launch: a meeting still marked as recording was cut off by a quit, crash or power loss. Keep what
    /// was saved and mark it, using the spool's own recovery pass.
    func recoverInterruptedRecordings() {
        for var record in meetings where record.status == .recording {
            guard let key = try? keys.load(for: record.id),
                  let spool = try? AudioSpool(root: root, meetingID: record.id, key: key) else {
                record.status = .unreadable
                update(record)
                continue
            }
            let recovery = spool.recover()
            record.microphoneSegments = recovery.readable[.microphone]?.count ?? 0
            record.systemSegments = recovery.readable[.system]?.count ?? 0
            record.damagedSegments = recovery.unreadable.count
            record.durationSeconds = Int((recovery.lastAudioEndMs ?? 0) / 1000)
            record.endedAt = record.startedAt.addingTimeInterval(TimeInterval(record.durationSeconds))
            record.status = .interrupted
            update(record)
        }
    }

    /// Destroy the key first (that alone makes the audio unrecoverable), then the files and the entry.
    func delete(_ record: MeetingRecord) {
        guard record.id != current?.id else { return }
        do { try keys.destroy(for: record.id) } catch {
            notices.append(MeetingNotice(text: "The recording’s key could not be removed from the Keychain, so it was kept.", kind: .warning))
            return
        }
        try? FileManager.default.removeItem(at: root.appendingPathComponent(record.id))
        meetings.removeAll { $0.id == record.id }
        saveIndex()
    }

    func revealInFinder() { NSWorkspace.shared.activateFileViewerSelecting([root]) }

    private func update(_ record: MeetingRecord) {
        if let i = meetings.firstIndex(where: { $0.id == record.id }) { meetings[i] = record } else { meetings.insert(record, at: 0) }
        saveIndex()
    }

    private var indexURL: URL { root.appendingPathComponent("index.json") }

    private func loadIndex() -> [MeetingRecord] {
        guard let data = try? Data(contentsOf: indexURL) else { return [] }
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode([MeetingRecord].self, from: data)) ?? []
    }

    private func saveIndex() {
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(meetings) else { return }
        let temp = root.appendingPathComponent(".index.json.tmp")
        guard FileManager.default.createFile(atPath: temp.path, contents: data, attributes: [.posixPermissions: 0o600]) else { return }
        _ = try? FileManager.default.replaceItemAt(indexURL, withItemAt: temp)
    }

    // MARK: Helpers

    static func newMeetingID() -> String {
        let f = DateFormatter(); f.dateFormat = "yyyyMMdd-HHmmss"; f.locale = Locale(identifier: "en_US_POSIX")
        let suffix = (0..<6).map { _ in String("0123456789abcdef".randomElement()!) }.joined()
        return "m-\(f.string(from: Date()))-\(suffix)"
    }

    static func name(_ channel: CaptureChannel) -> String { channel == .microphone ? "The microphone" : "System audio" }

    static func describe(_ error: Error) -> String {
        switch error {
        case CaptureError.notEnoughDiskSpace: return "Recording needs at least 2 GB of free disk space."
        case CaptureError.microphoneDenied: return "Device Studio can’t use the microphone."
        case CaptureError.microphoneUnavailable: return "No microphone is available."
        case CaptureError.tapUnavailable, CaptureError.aggregateDeviceFailed, CaptureError.ioFailed:
            return "System audio can’t be recorded on this Mac right now."
        case is KeyStoreError: return "The recording’s encryption key could not be saved to the Keychain."
        case is SpoolError: return "The recording folder could not be created."
        default: return "Recording could not start."
        }
    }

    static func duration(_ seconds: Int) -> String {
        let h = seconds / 3600, m = (seconds % 3600) / 60, s = seconds % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
    }
}
