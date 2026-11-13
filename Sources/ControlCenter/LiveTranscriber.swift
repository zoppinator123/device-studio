import CaptureKit
import Foundation

/// Live transcription of one channel: a long-running speech engine (`engine-transcribe --stream`) that
/// receives each audio segment as soon as it is captured and prints text a moment after the speaker
/// pauses. Network access is denied to it; audio goes in through a pipe and is never written to disk.
final class LiveTranscriber {
    let channel: CaptureChannel
    private let process = Process()
    private let input = Pipe()
    private let output = Pipe()
    private let writes: DispatchQueue
    private let onLine: (TimedText) -> Void
    private let finished = DispatchGroup()
    private var broken = false

    /// `onLine` is called on a background thread for every finished line.
    init(channel: CaptureChannel, engine: NotesEngine, onLine: @escaping (TimedText) -> Void) throws {
        self.channel = channel
        self.onLine = onLine
        writes = DispatchQueue(label: "com.jackzoppa.devicestudio.live.\(channel.rawValue)")
        process.executableURL = URL(fileURLWithPath: "/usr/bin/sandbox-exec")
        process.arguments = ["-p", "(version 1)(allow default)(deny network*)", engine.transcriber.path,
                             "--model", engine.speechModel.path, "--language", "en", "--stream"]
        process.currentDirectoryURL = FileManager.default.temporaryDirectory
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice      // may echo text; never kept
        try process.run()
        finished.enter()
        let reader = output.fileHandleForReading
        Thread.detachNewThread { [self] in
            var pending = Data()
            while true {
                let chunk = reader.availableData
                if chunk.isEmpty { break }
                pending.append(chunk)
                while let newline = pending.firstIndex(of: 0x0A) {
                    let line = pending[pending.startIndex..<newline]
                    pending.removeSubrange(pending.startIndex...newline)
                    if let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                       let text = object["text"] as? String,
                       let start = (object["start_ms"] as? NSNumber)?.int64Value,
                       let end = (object["end_ms"] as? NSNumber)?.int64Value {
                        self.onLine(TimedText(channel: self.channel, startMs: start, endMs: end, text: text))
                    }
                }
            }
            self.finished.leave()
        }
    }

    /// Hand over one captured segment. Never blocks the caller.
    func send(_ segment: AudioSegment) {
        writes.async { [self] in
            guard !broken else { return }
            var frame = Data(capacity: 12 + segment.samples.count * 4)
            withUnsafeBytes(of: segment.startMs.littleEndian) { frame.append(contentsOf: $0) }
            withUnsafeBytes(of: UInt32(segment.samples.count).littleEndian) { frame.append(contentsOf: $0) }
            segment.samples.withUnsafeBufferPointer { frame.append(Data(buffer: $0)) }
            do { try input.fileHandleForWriting.write(contentsOf: frame) } catch { broken = true }
        }
    }

    /// End of meeting: the engine transcribes what it still holds, prints it, and exits. Blocks until then
    /// (call it off the main thread). Returns false if the engine had stopped early.
    @discardableResult
    func finish(timeout: TimeInterval = 120) -> Bool {
        writes.sync { try? input.fileHandleForWriting.close() }
        let clean = finished.wait(timeout: .now() + timeout) == .success
        if !clean { process.terminate() }
        process.waitUntilExit()
        return clean && !broken && process.terminationStatus == 0
    }

    func cancel() {
        writes.sync { try? input.fileHandleForWriting.close() }
        if process.isRunning { process.terminate() }
    }
}
