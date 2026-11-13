import CaptureKit
import CryptoKit
import Foundation

/// The local engines that turn a recording into a transcript and notes. They are not bundled with Device
/// Studio: they live in a separate folder (the "notes engine"), chosen on the Meetings page. Both run as
/// child processes with network access denied, and get audio and text through pipes only, so nothing
/// unencrypted is written to disk.
struct NotesEngine {
    /// The speech model is pinned by exact size and SHA-256, checked before every use.
    static let speechModelRelativePath =
        ".local/share/meeting-notetaker/models/handy-computer--parakeet-tdt-0.6b-v3-gguf@85ac09ea12fc4b1112fa76810059364bc6adc9de/parakeet-tdt-0.6b-v3-Q8_0.gguf"
    static let speechModelSize: UInt64 = 739_508_576
    static let speechModelSHA256 = "5859f77944efcd8eafa23a6350731960b2b55b2203df51f319665c807d802cc7"

    let root: URL
    var transcriber: URL { root.appendingPathComponent("engine/target/release/engine-transcribe") }
    var python: URL { root.appendingPathComponent(".venv/bin/python") }
    var notesScript: URL { root.appendingPathComponent("notes-runner/run_notes.py") }
    var speechModel: URL { FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(Self.speechModelRelativePath) }

    /// What is missing, in plain words, or nil when everything is in place.
    var problem: String? {
        let fm = FileManager.default
        if !fm.isExecutableFile(atPath: transcriber.path) { return "The transcription engine isn’t built in this folder." }
        if !fm.isExecutableFile(atPath: python.path) || !fm.fileExists(atPath: notesScript.path) { return "The notes engine isn’t set up in this folder." }
        if !fm.fileExists(atPath: speechModel.path) { return "The speech model hasn’t been downloaded." }
        return nil
    }

    /// The folder in the settings, or the usual location when none is set.
    static func resolve(_ setting: String) -> NotesEngine {
        if !setting.isEmpty { return NotesEngine(root: URL(fileURLWithPath: (setting as NSString).expandingTildeInPath)) }
        return NotesEngine(root: FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".t3/projects/meeting-notetaker"))
    }

    func verifySpeechModel() throws {
        let attributes = try FileManager.default.attributesOfItem(atPath: speechModel.path)
        guard (attributes[.size] as? NSNumber)?.uint64Value == Self.speechModelSize else { throw ProcessingError.modelMismatch }
        guard let handle = FileHandle(forReadingAtPath: speechModel.path) else { throw ProcessingError.modelMismatch }
        defer { try? handle.close() }
        var hash = SHA256()
        while let chunk = try handle.read(upToCount: 8 << 20), !chunk.isEmpty { hash.update(data: chunk) }
        let hex = hash.finalize().map { String(format: "%02x", $0) }.joined()
        guard hex == Self.speechModelSHA256 else { throw ProcessingError.modelMismatch }
    }
}

enum ProcessingError: Error, LocalizedError {
    case engineMissing(String)
    case modelMismatch
    case nothingRecorded
    case engineFailed(String)

    var errorDescription: String? {
        switch self {
        case .engineMissing(let why): return why
        case .modelMismatch: return "The speech model file doesn’t match its pinned checksum, so it wasn’t used."
        case .nothingRecorded: return "This recording has no readable audio."
        case .engineFailed(let why): return why
        }
    }
}

/// Runs the two engines for one meeting. Not on the main thread: transcription takes seconds and notes
/// about a minute or two.
enum MeetingProcessor {
    private static let noNetwork = "(version 1)(allow default)(deny network*)"

    static func transcribe(spool: AudioSpool, channels: [CaptureChannel], engine: NotesEngine, speakers: SpeakerTimeline? = nil) throws -> (text: String, echoesDropped: Int) {
        if let problem = engine.problem { throw ProcessingError.engineMissing(problem) }
        try engine.verifySpeechModel()
        var lines: [TimedText] = []
        var anyAudio = false
        for channel in channels {
            let segments = spool.readableSegments(channel)
            guard !segments.isEmpty else { continue }
            anyAudio = true
            var input = Data()
            for segment in segments {
                withUnsafeBytes(of: segment.startMs.littleEndian) { input.append(contentsOf: $0) }
                withUnsafeBytes(of: UInt32(segment.samples.count).littleEndian) { input.append(contentsOf: $0) }
                segment.samples.withUnsafeBufferPointer { input.append(Data(buffer: $0)) }
            }
            let output = try run(engine.transcriber, ["--model", engine.speechModel.path, "--language", "en"], input: input)
            for line in output.split(separator: "\n") {
                guard let object = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                      let text = object["text"] as? String,
                      let start = (object["start_ms"] as? NSNumber)?.int64Value,
                      let end = (object["end_ms"] as? NSNumber)?.int64Value else { continue }
                lines.append(TimedText(channel: channel, startMs: start, endMs: end, text: text))
            }
            input.resetBytes(in: 0..<input.count)          // do not leave audio lying in freed memory longer than needed
        }
        guard anyAudio else { throw ProcessingError.nothingRecorded }
        let merged = TranscriptAssembler.merge(speakers?.label(lines) ?? lines)
        return (TranscriptAssembler.render(merged.lines), merged.echoesDropped)
    }

    static func makeNotes(transcript: String, title: String, date: Date, attendees: [String] = [], engine: NotesEngine) throws -> (markdown: String, json: Data) {
        if let problem = engine.problem { throw ProcessingError.engineMissing(problem) }
        var fields: [String: Any] = ["title": title, "date": ISO8601DateFormatter().string(from: date)]
        if !attendees.isEmpty { fields["attendees"] = attendees }
        let meta = try JSONSerialization.data(withJSONObject: fields)
        let output = try run(engine.python, ["-I", engine.notesScript.path, "--stdin", "--json-stdout",
                                             "--meta-json", String(decoding: meta, as: UTF8.self)],
                             input: Data(transcript.utf8))
        guard let last = output.split(separator: "\n").last,
              let object = try? JSONSerialization.jsonObject(with: Data(last.utf8)) as? [String: Any],
              let markdown = object["markdown"] as? String else {
            throw ProcessingError.engineFailed("The notes engine finished without notes.")
        }
        return (markdown, Data(last.utf8))
    }

    /// Run a helper with network access denied. Input goes in through stdin, results come back on stdout.
    private static func run(_ executable: URL, _ arguments: [String], input: Data) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/sandbox-exec")
        process.arguments = ["-p", noNetwork, executable.path] + arguments
        process.currentDirectoryURL = FileManager.default.temporaryDirectory
        let stdin = Pipe(), stdout = Pipe(), stderr = Pipe()
        process.standardInput = stdin; process.standardOutput = stdout; process.standardError = stderr
        try process.run()
        var out = Data(), err = Data()
        let group = DispatchGroup()
        group.enter(); DispatchQueue.global().async { out = stdout.fileHandleForReading.readDataToEndOfFile(); group.leave() }
        group.enter(); DispatchQueue.global().async { err = stderr.fileHandleForReading.readDataToEndOfFile(); group.leave() }
        do {
            try stdin.fileHandleForWriting.write(contentsOf: input)
            try stdin.fileHandleForWriting.close()
        } catch {
            process.terminate()
        }
        process.waitUntilExit()
        group.wait()
        guard process.terminationStatus == 0 else {
            // stderr can echo meeting text in a traceback, so it is discarded, never logged.
            err.resetBytes(in: 0..<err.count)
            NSLog("Device Studio: %@ exited with status %d", executable.lastPathComponent, process.terminationStatus)
            throw ProcessingError.engineFailed("\(executable.lastPathComponent == "engine-transcribe" ? "Transcription" : "Note writing") failed (exit \(process.terminationStatus)).")
        }
        return String(decoding: out, as: UTF8.self)
    }
}
