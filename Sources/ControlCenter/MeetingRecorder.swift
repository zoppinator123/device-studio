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
        case transcribing
        case makingNotes
        case ready          // transcript and notes are saved, encrypted
        case failed         // transcript or notes could not be made; `problem` says why
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
    var problem: String?
    var echoesDropped: Int?
    var notesSeconds: Int?
    /// False when only the live transcript was kept (nil for recordings made before that option existed).
    var audioKept: Bool?
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
    /// The live transcript of the meeting being recorded, both channels merged, echo removed.
    @Published private(set) var liveLines: [TimedText] = []
    /// Google Meet tabs connected through the Chrome extension.
    @Published private(set) var meetTabs = 0
    /// People named by Google Meet during this recording.
    @Published private(set) var meetNames: [String] = []
    /// Called whenever recording starts or stops, so the Chrome extension can follow.
    var onRecordingChange: ((Bool) -> Void)?
    /// What the page is showing in its reader sheet.
    @Published var reading: Reading?
    struct Reading: Identifiable { let id = UUID(); let title: String; let text: String }
    /// Settings, kept current by AppModel.
    var settings = MeetingSettings()
    var engine: NotesEngine { NotesEngine.resolve(settings.enginePath) }
    @Published var showExplainer = false

    let root: URL
    private let keys = MeetingKeyStore(service: "com.jackzoppa.devicestudio.meeting-key")
    private var session: CaptureSession?
    private var current: MeetingRecord?
    private var ticker: AnyCancellable?
    private var transcribers: [CaptureChannel: LiveTranscriber] = [:]
    private var rawLines: [TimedText] = []
    private var speakers = SpeakerTimeline()
    /// The moment the capture clock read zero, to place caption times on the meeting's clock.
    private var clockZero: Date?
    private var meetTitle: String?
    private var currentSpool: AudioSpool?
    private let sealQueue = DispatchQueue(label: "com.jackzoppa.devicestudio.transcript-seal")

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
        var record = MeetingRecord(id: id, startedAt: Date(), sources: sources.map(\.rawValue).sorted())
        let engine = self.engine
        let live = engine.problem == nil
        guard live || settings.keepAudio else {
            notices.append(MeetingNotice(text: "Live transcription isn’t available: \(engine.problem ?? ""). Turn on “Keep audio” to record without it.", kind: .warning))
            return
        }
        record.audioKept = settings.keepAudio
        do {
            // The key and the meeting's entry are saved before the first sample is accepted.
            let key = try keys.create(for: id)
            let spool = try AudioSpool(root: root, meetingID: id, key: key)
            meetings.insert(record, at: 0)
            saveIndex()
            var configuration = CaptureSession.Configuration()
            configuration.sources = sources
            configuration.echoCancellation = EchoCancellation(rawValue: settings.echo.rawValue) ?? .off
            configuration.spoolAudio = settings.keepAudio
            configuration.segmentSeconds = live ? 1 : 5
            rawLines = []; liveLines = []; transcribers = [:]
            speakers = SpeakerTimeline(); meetNames = []; meetTitle = nil
            if live {
                try engine.verifySpeechModel()
                for channel in sources {
                    transcribers[channel] = try LiveTranscriber(channel: channel, engine: engine) { [weak self] line in
                        Task { @MainActor in self?.appendLive(line) }
                    }
                }
            }
            currentSpool = spool
            let session = CaptureSession(spool: spool, configuration: configuration) { [weak self] event in
                Task { @MainActor in self?.handle(event) }
            }
            clockZero = Date()
            try session.start()
            self.session = session
            current = record
            startedAt = record.startedAt
            elapsed = 0
            isRecording = true
            onRecordingChange?(true)
            ticker = Timer.publish(every: 1, on: .main, in: .common).autoconnect().sink { [weak self] _ in
                guard let self, let startedAt = self.startedAt else { return }
                self.elapsed = Date().timeIntervalSince(startedAt)
            }
        } catch {
            transcribers.values.forEach { $0.cancel() }
            transcribers = [:]
            currentSpool = nil
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
            transcribers[segment.channel]?.send(segment)
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
            var finished: MeetingRecord?
            if var record = current {
                record.endedAt = Date()
                record.durationSeconds = Int(summary.endMs / 1000)
                record.microphoneSegments = summary.segments[.microphone] ?? 0
                record.systemSegments = summary.segments[.system] ?? 0
                record.status = .recorded
                update(record)
                finished = record
            }
            current = nil
            session = nil
            isRecording = false
            onRecordingChange?(false)
            startedAt = nil
            ticker = nil
            askWhetherToStop = false
            systemAudioPath = nil
            echoState = nil
            if let finished, !transcribers.isEmpty {
                finishLive(finished)
            } else if let finished, settings.autoNotes, engine.problem == nil {
                makeNotes(finished)
            }
        }
    }

    // MARK: Live transcript

    private func appendLive(_ line: TimedText) {
        var line = line
        if line.channel == .system { line.speaker = speakers.speaker(for: line) }
        rawLines.append(line)
        liveLines = TranscriptAssembler.merge(rawLines).lines
        saveLiveTranscript()
    }

    /// The transcript is sealed to disk after every new line, so a crash or power cut keeps it.
    private func saveLiveTranscript() {
        guard let spool = currentSpool else { return }
        let text = TranscriptAssembler.render(liveLines)
        sealQueue.async { try? spool.writeSealed("transcript", Data(text.utf8)) }
        if var record = current, isRecording {
            record.durationSeconds = Int(elapsed)
            current = record
            update(record)
        }
    }

    /// After Stop: let the engines finish what they still hold, save the final transcript, then write notes.
    private func finishLive(_ record: MeetingRecord) {
        var working = record
        working.status = .transcribing
        update(working)
        let pending = Array(transcribers.values)
        transcribers = [:]
        Task.detached(priority: .userInitiated) {
            let clean = pending.map { $0.finish() }.allSatisfy { $0 }
            await MainActor.run {
                self.rawLines = self.speakers.label(self.rawLines)
                self.saveSpeakers()
                let merged = TranscriptAssembler.merge(self.rawLines)
                self.liveLines = merged.lines
                self.saveLiveTranscript()
                self.sealQueue.sync {}
                self.currentSpool = nil
                working.echoesDropped = merged.echoesDropped
                if !clean { working.problem = "Part of the transcript may be missing: the speech engine stopped early." }
                if merged.lines.isEmpty {
                    working.status = .failed
                    working.problem = "Nothing was heard during this meeting."
                    self.update(working)
                } else if self.settings.autoNotes {
                    working.status = .recorded
                    self.update(working)
                    self.makeNotes(working)
                } else {
                    working.status = .recorded
                    self.update(working)
                }
            }
        }
    }

    // MARK: Google Meet speakers

    /// One message from the Chrome extension. Only used while recording, and only kept in memory, except
    /// that the names and captions are sealed with the meeting's key at the end so notes can be made again.
    func meetMessage(_ message: [String: Any]) {
        guard isRecording, settings.meetSpeakers, let zero = clockZero else { return }
        switch message["type"] as? String {
        case "caption":
            guard let speaker = message["speaker"] as? String, let text = message["text"] as? String,
                  let at = (message["at"] as? NSNumber)?.doubleValue, text.count <= 2_000 else { return }
            let ms = Int64(at - zero.timeIntervalSince1970 * 1000)
            guard ms >= -10_000, ms <= Int64(elapsed * 1000) + 60_000 else { return }
            speakers.add(speaker: speaker, text: text, atMs: ms)
            relabelRecent(around: ms)
        case "participants":
            for name in (message["names"] as? [String] ?? []).prefix(200) { speakers.note(name) }
        case "meeting":
            if let title = message["title"] as? String, !title.isEmpty, title.count <= 200 { meetTitle = title }
        default:
            return
        }
        if meetNames != speakers.names { meetNames = speakers.names }
    }

    func meetTabsChanged(_ count: Int) { meetTabs = count }

    /// Captions trail the audio, so a line that arrived before its caption is named once the caption comes.
    private func relabelRecent(around ms: Int64) {
        var changed = false
        for i in rawLines.indices.reversed() {
            let line = rawLines[i]
            if line.endMs < ms - 20_000 { break }
            guard line.channel == .system else { continue }
            let name = speakers.speaker(for: line)
            if name != line.speaker { rawLines[i].speaker = name; changed = true }
        }
        guard changed else { return }
        liveLines = TranscriptAssembler.merge(rawLines).lines
        saveLiveTranscript()
    }

    private func saveSpeakers() {
        guard let spool = currentSpool, !speakers.captions.isEmpty || !speakers.names.isEmpty,
              let data = try? JSONEncoder().encode(SavedSpeakers(title: meetTitle, timeline: speakers)) else { return }
        sealQueue.async { try? spool.writeSealed("speakers", data) }
    }

    // MARK: Transcript and notes

    /// Transcribe both channels and write notes, entirely on this Mac. Results are sealed with the
    /// meeting's own key next to its audio.
    func makeNotes(_ record: MeetingRecord) {
        guard !isRecording || record.id != current?.id else { return }
        guard ![.transcribing, .makingNotes, .unreadable].contains(record.status) else { return }
        let engine = self.engine
        var working = record
        working.status = .transcribing
        working.problem = nil
        update(working)
        let root = self.root, keys = self.keys
        Task.detached(priority: .userInitiated) {
            let started = Date()
            do {
                let key = try keys.load(for: record.id)
                let spool = try AudioSpool(root: root, meetingID: record.id, key: key)
                let channels = record.sources.compactMap(CaptureChannel.init(rawValue:))
                let transcript: (text: String, echoesDropped: Int)
                if record.audioKept == false {
                    // Transcript-only meeting: the live transcript is the source.
                    guard let saved = try spool.readSealed("transcript"), !saved.isEmpty else { throw ProcessingError.nothingRecorded }
                    transcript = (String(decoding: saved, as: UTF8.self), record.echoesDropped ?? 0)
                } else {
                    let timeline = (try? spool.readSealed("speakers")).flatMap { try? JSONDecoder().decode(SavedSpeakers.self, from: $0) }
                    transcript = try MeetingProcessor.transcribe(spool: spool, channels: channels, engine: engine, speakers: timeline?.timeline)
                    try spool.writeSealed("transcript", Data(transcript.text.utf8))
                }
                await MainActor.run {
                    working.status = .makingNotes
                    working.echoesDropped = transcript.echoesDropped
                    self.update(working)
                }
                let saved = (try? spool.readSealed("speakers")).flatMap { try? JSONDecoder().decode(SavedSpeakers.self, from: $0) }
                let title = saved?.title.flatMap { $0.isEmpty ? nil : $0 } ?? "Meeting " + record.startedAt.formatted(date: .abbreviated, time: .shortened)
                let notes = try MeetingProcessor.makeNotes(transcript: transcript.text, title: title, date: record.startedAt,
                                                           attendees: saved?.timeline.names ?? [], engine: engine)
                try spool.writeSealed("notes", Data(notes.markdown.utf8))
                try spool.writeSealed("notes-json", notes.json)
                await MainActor.run {
                    working.status = .ready
                    working.notesSeconds = Int(Date().timeIntervalSince(started))
                    self.update(working)
                }
            } catch {
                await MainActor.run {
                    working.status = .failed
                    working.problem = (error as? LocalizedError)?.errorDescription ?? "Notes could not be made."
                    self.update(working)
                }
            }
        }
    }

    /// Decrypt and show a meeting's notes or transcript.
    func open(_ record: MeetingRecord, kind: String) {
        do {
            let key = try keys.load(for: record.id)
            let spool = try AudioSpool(root: root, meetingID: record.id, key: key)
            guard let data = try spool.readSealed(kind) else { return }
            let when = record.startedAt.formatted(date: .abbreviated, time: .shortened)
            reading = Reading(title: (kind == "notes" ? "Notes · " : "Transcript · ") + when, text: String(decoding: data, as: UTF8.self))
        } catch {
            notices.append(MeetingNotice(text: "That file could not be opened. It may be damaged, or its key is missing.", kind: .warning))
        }
    }

    func hasSealed(_ record: MeetingRecord, _ kind: String) -> Bool {
        FileManager.default.fileExists(atPath: root.appendingPathComponent(record.id).appendingPathComponent("\(kind).sealed").path)
    }

    // MARK: Library

    /// On launch: a meeting still marked as recording was cut off by a quit, crash or power loss. Keep what
    /// was saved and mark it, using the spool's own recovery pass.
    func recoverInterruptedRecordings() {
        // Notes that were being made when the app stopped: let them be made again.
        for var record in meetings where record.status == .transcribing || record.status == .makingNotes {
            record.status = .failed
            record.problem = "Device Studio quit before the notes were finished."
            update(record)
        }
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
            if record.audioKept != false { record.durationSeconds = Int((recovery.lastAudioEndMs ?? 0) / 1000) }
            record.endedAt = record.startedAt.addingTimeInterval(TimeInterval(record.durationSeconds))
            record.status = .interrupted
            update(record)
        }
    }

    /// Destroy the key first (that alone makes the audio unrecoverable), then the files and the entry.
    func delete(_ record: MeetingRecord) {
        guard record.id != current?.id, record.status != .transcribing, record.status != .makingNotes else { return }
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

/// What Google Meet told us about a meeting, sealed with the meeting's key.
struct SavedSpeakers: Codable {
    var title: String?
    var timeline: SpeakerTimeline
}
