import AVFoundation
import CaptureKit
import CryptoKit
import Foundation

/// `DeviceStudio --self-test-notes`: checks the whole recording-to-notes path without a microphone. It
/// speaks two invented lines with the system voice, seals them into a throwaway encrypted spool as a
/// microphone and a system-audio channel, then runs the real transcription and notes engines. Nothing
/// from a real meeting is used, and the throwaway files are removed afterwards.
enum NotesSelfTest {
    static func run() -> Int32 {
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent("ds-selftest-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: temp) }
        do {
            try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
            let mic = try speak("The database is at ninety five percent memory and crashed twice today.", in: temp, name: "mic")
            let sys = try speak("I will upgrade the plan by Friday and ask the vendor about the forty dollar invoice.", in: temp, name: "sys")
            let spool = try AudioSpool(root: temp, meetingID: "m-selftest", key: SymmetricKey(size: .bits256))
            try write(mic, channel: .microphone, startMs: 1_000, to: spool)
            try write(sys, channel: .system, startMs: 8_000, to: spool)
            let engine = NotesEngine.resolve(CommandLine.arguments.drop { $0 != "--engine" }.dropFirst().first ?? "")
            print("Engine folder: \(engine.root.path)")
            if let problem = engine.problem { print("FAIL: \(problem)"); return 1 }
            var t0 = Date()
            let transcript = try MeetingProcessor.transcribe(spool: spool, channels: [.microphone, .system], engine: engine)
            print(String(format: "Transcribed in %.1f s:", Date().timeIntervalSince(t0)))
            print(transcript.text)
            t0 = Date()
            let notes = try MeetingProcessor.makeNotes(transcript: transcript.text, title: "Self test", date: Date(), engine: engine)
            print(String(format: "Notes in %.1f s:", Date().timeIntervalSince(t0)))
            print(notes.markdown)
            let ok = transcript.text.contains("Me:") && transcript.text.contains("Others:") && notes.markdown.contains("### Summary")
            print(ok ? "PASS: recording-to-notes path works" : "FAIL: unexpected output")
            return ok ? 0 : 1
        } catch {
            print("FAIL: \((error as? LocalizedError)?.errorDescription ?? String(describing: error))")
            return 1
        }
    }

    /// `--self-test-live`: the live path. Two invented speakers are fed to two live engines in real time,
    /// one second at a time, as during a meeting; reports how soon each line appears after it is spoken.
    static func runLive() -> Int32 {
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent("ds-selftest-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: temp) }
        do {
            try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
            let me = try speak("First point. The database is at ninety five percent memory.", in: temp, name: "me")
            let them = try speak("Got it. I will upgrade the plan by Friday.", in: temp, name: "them")
            let engine = NotesEngine.resolve("")
            if let problem = engine.problem { print("FAIL: \(problem)"); return 1 }
            try engine.verifySpeechModel()
            let lock = NSLock(); var lines: [(TimedText, TimeInterval)] = []
            let started = Date()
            let transcribers = try [CaptureChannel.microphone, .system].map { channel in
                try LiveTranscriber(channel: channel, engine: engine) { line in
                    lock.lock(); lines.append((line, Date().timeIntervalSince(started))); lock.unlock()
                    print(String(format: "  +%4.1fs  %@: %@", Date().timeIntervalSince(started), channel == .microphone ? "Me" : "Them", line.text))
                }
            }
            Thread.sleep(forTimeInterval: 4)     // let both engines load, as they do when recording starts
            // Me talks from 0 s, Them answers from 6 s; 1-second segments, sent when their second has passed.
            let total = 12
            let clockStart = Date()
            for second in 0..<total {
                for (index, samples) in [me, them].enumerated() {
                    let offset = (index == 0 ? 0 : 6) * 16_000
                    let from = second * 16_000 - offset
                    var chunk = [Float](repeating: 0, count: 16_000)
                    for i in 0..<16_000 where from + i >= 0 && from + i < samples.count { chunk[i] = samples[from + i] }
                    transcribers[index].send(AudioSegment(channel: index == 0 ? .microphone : .system, sequence: second,
                                                          startMs: Int64(second) * 1_000, sampleRate: 16_000, samples: chunk))
                }
                Thread.sleep(until: clockStart.addingTimeInterval(Double(second + 1)))
            }
            let ok = transcribers.map { $0.finish() }.allSatisfy { $0 }
            let merged = TranscriptAssembler.merge(lines.map(\.0)).lines
            print("Transcript:\n" + TranscriptAssembler.render(merged))
            let pass = ok && merged.contains { $0.channel == .microphone } && merged.contains { $0.channel == .system }
            print(pass ? "PASS: live transcription works" : "FAIL: missing lines")
            return pass ? 0 : 1
        } catch {
            print("FAIL: \((error as? LocalizedError)?.errorDescription ?? String(describing: error))")
            return 1
        }
    }

    private static func speak(_ text: String, in dir: URL, name: String) throws -> [Float] {
        let aiff = dir.appendingPathComponent("\(name).aiff"), wav = dir.appendingPathComponent("\(name).wav")
        for (tool, args) in [("/usr/bin/say", ["-o", aiff.path, text]),
                             ("/usr/bin/afconvert", ["-f", "WAVE", "-d", "LEF32@16000", "-c", "1", aiff.path, wav.path])] {
            let p = Process(); p.executableURL = URL(fileURLWithPath: tool); p.arguments = args
            try p.run(); p.waitUntilExit()
            guard p.terminationStatus == 0 else { throw ProcessingError.engineFailed("\(tool) failed") }
        }
        let file = try AVAudioFile(forReading: wav)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)) else { return [] }
        try file.read(into: buffer)
        return Array(UnsafeBufferPointer(start: buffer.floatChannelData![0], count: Int(buffer.frameLength)))
    }

    private static func write(_ samples: [Float], channel: CaptureChannel, startMs: Int64, to spool: AudioSpool) throws {
        var assembler = SegmentAssembler(channel: channel)
        var segments = assembler.append(samples, atMs: startMs)
        if let last = assembler.flush() { segments.append(last) }
        for s in segments { try spool.append(s) }
    }
}
