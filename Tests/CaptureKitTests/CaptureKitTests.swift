import AVFoundation
import CryptoKit
import XCTest
@testable import CaptureKit

final class HostClockTests: XCTestCase {
    func testMillisecondsFromHostTicks() {
        // Apple silicon timebase: 125/3 nanoseconds per tick.
        let clock = HostClock(startHostTime: 10_000_000, timebase: (125, 3))
        XCTAssertEqual(clock.milliseconds(for: 10_000_000), 0)
        XCTAssertEqual(clock.milliseconds(for: 10_000_000 + 24_000_000), 1_000)     // 24M ticks = 1 s
        XCTAssertEqual(clock.milliseconds(for: 10_000_000 - 2_400_000), -100)
    }

    func testNoOverflowOverALongRecording() {
        let clock = HostClock(startHostTime: 0, timebase: (125, 3))
        let eightHoursOfTicks: UInt64 = 8 * 3_600 * 24_000_000
        XCTAssertEqual(clock.milliseconds(for: eightHoursOfTicks), 8 * 3_600_000)
        // A timebase with a large numerator would overflow 64 bits without the wide multiply.
        let wide = HostClock(startHostTime: 0, timebase: (1_000_000_000, 1))
        XCTAssertEqual(wide.milliseconds(for: 30_000_000_000), 30_000_000_000 * 1_000)
    }
}

final class SegmentAssemblerTests: XCTestCase {
    func testCutsFiveSecondSegmentsWithRunningStartTimes() {
        var a = SegmentAssembler(channel: .microphone)
        var out: [AudioSegment] = []
        for i in 0..<12 {        // 12 one-second buffers
            out += a.append([Float](repeating: 0.1, count: 16_000), atMs: Int64(i) * 1_000)
        }
        XCTAssertEqual(out.map(\.sequence), [0, 1])
        XCTAssertEqual(out.map(\.startMs), [0, 5_000])
        XCTAssertEqual(out.map(\.samples.count), [80_000, 80_000])
        let tail = a.flush()
        XCTAssertEqual(tail?.sequence, 2)
        XCTAssertEqual(tail?.startMs, 10_000)
        XCTAssertEqual(tail?.samples.count, 32_000)
        XCTAssertNil(a.flush())
    }

    func testAGapStartsANewSegmentAtItsRealTimeInsteadOfShiftingAudio() {
        var a = SegmentAssembler(channel: .system)
        XCTAssertEqual(a.append([Float](repeating: 0.1, count: 16_000), atMs: 0), [])
        // The tap restarted: the next buffer arrives 30 s later, not at 1 s.
        let out = a.append([Float](repeating: 0.2, count: 16_000), atMs: 30_000)
        XCTAssertEqual(out.count, 1)
        XCTAssertEqual(out[0].startMs, 0)
        XCTAssertEqual(out[0].samples.count, 16_000)
        let rest = a.flush()
        XCTAssertEqual(rest?.startMs, 30_000)          // the gap is visible between the two segments
        XCTAssertEqual(rest?.sequence, 1)
    }

    func testSmallJitterDoesNotSplit() {
        var a = SegmentAssembler(channel: .microphone)
        _ = a.append([Float](repeating: 0, count: 1_600), atMs: 0)       // 100 ms
        XCTAssertEqual(a.append([Float](repeating: 0, count: 1_600), atMs: 108), [])   // 8 ms late: same segment
        XCTAssertEqual(a.flush()?.samples.count, 3_200)
    }
}

final class WatchdogTests: XCTestCase {
    private func limits() -> CaptureWatchdog.Limits { CaptureWatchdog.Limits() }

    func testStallIsReportedOnceAndClearsWhenAudioReturns() {
        var w = CaptureWatchdog(channels: [.microphone, .system])
        w.noteBuffer(.microphone, atMs: 1_000, peak: 0.2)
        w.noteBuffer(.system, atMs: 1_000, peak: 0.2)
        XCTAssertEqual(w.evaluate(nowMs: 2_000, outputDeviceIsRunning: true), [])
        w.noteBuffer(.microphone, atMs: 4_500, peak: 0.2)                // system stops delivering
        XCTAssertEqual(w.evaluate(nowMs: 4_600, outputDeviceIsRunning: true), [.stalled(.system)])
        XCTAssertEqual(w.evaluate(nowMs: 5_600, outputDeviceIsRunning: true), [])            // already reported
        XCTAssertEqual(w.evaluate(nowMs: 7_600, outputDeviceIsRunning: true), [.stalled(.microphone)])
        w.noteBuffer(.system, atMs: 8_000, peak: 0.2)
        w.noteBuffer(.microphone, atMs: 8_000, peak: 0.2)
        XCTAssertEqual(w.evaluate(nowMs: 8_100, outputDeviceIsRunning: true), [])
        XCTAssertEqual(w.evaluate(nowMs: 11_100, outputDeviceIsRunning: true), [.stalled(.microphone), .stalled(.system)])
    }

    func testAllZeroSystemAudioWhileSomethingPlaysLooksLikeADenial() {
        var w = CaptureWatchdog(channels: [.microphone, .system])
        for t in stride(from: Int64(0), through: 6_000, by: 500) {
            w.noteBuffer(.system, atMs: t, peak: 0)            // buffers arrive, all zeros
            w.noteBuffer(.microphone, atMs: t, peak: 0.3)
        }
        XCTAssertEqual(w.evaluate(nowMs: 6_000, outputDeviceIsRunning: false), [])   // nothing playing: no verdict
        XCTAssertEqual(w.evaluate(nowMs: 6_100, outputDeviceIsRunning: true), [.systemAudioLooksDenied])
        XCTAssertEqual(w.evaluate(nowMs: 6_200, outputDeviceIsRunning: true), [])    // once
    }

    func testLongSilenceAsksThenStopsAndTheAnswerResetsIt() {
        var w = CaptureWatchdog(channels: [.microphone, .system])
        func feed(_ t: Int64) { w.noteBuffer(.microphone, atMs: t, peak: 0.00001); w.noteBuffer(.system, atMs: t, peak: 0.00001) }
        let ask = limits().silenceAskMs, grace = limits().silenceGraceMs
        feed(ask - 1_000)
        XCTAssertEqual(w.evaluate(nowMs: ask - 1_000, outputDeviceIsRunning: false), [])
        feed(ask)
        XCTAssertEqual(w.evaluate(nowMs: ask, outputDeviceIsRunning: false), [.askWhetherToStop])
        w.keepRecording(atMs: ask + 10_000)                     // "keep recording"
        feed(ask + grace + 10_000)
        XCTAssertEqual(w.evaluate(nowMs: ask + grace + 10_000, outputDeviceIsRunning: false), [])
        feed(2 * ask + 10_000)
        XCTAssertEqual(w.evaluate(nowMs: 2 * ask + 10_000, outputDeviceIsRunning: false), [.askWhetherToStop])
        feed(2 * ask + grace + 10_000)
        XCTAssertEqual(w.evaluate(nowMs: 2 * ask + grace + 10_000, outputDeviceIsRunning: false), [.autoStop])
    }

    func testSpeechOnEitherChannelKeepsTheSilenceTimerAway() {
        var w = CaptureWatchdog(channels: [.microphone, .system])
        let ask = limits().silenceAskMs
        w.noteBuffer(.microphone, atMs: ask - 5_000, peak: 0.2)   // someone spoke 5 s before the limit
        w.noteBuffer(.system, atMs: ask, peak: 0)
        w.noteBuffer(.microphone, atMs: ask, peak: 0)
        XCTAssertEqual(w.evaluate(nowMs: ask, outputDeviceIsRunning: false), [])
    }

    func testHardCap() {
        var w = CaptureWatchdog(channels: [.microphone])
        let cap = limits().hardCapMs
        w.noteBuffer(.microphone, atMs: cap, peak: 0.2)
        XCTAssertEqual(w.evaluate(nowMs: cap, outputDeviceIsRunning: false), [.hardCapReached])
    }
}

final class AudioSpoolTests: XCTestCase {
    private var root: URL!
    private let key = SymmetricKey(size: .bits256)

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("spool-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDown() { try? FileManager.default.removeItem(at: root) }

    private func segment(_ channel: CaptureChannel, _ seq: Int, start: Int64 = 0, fill: Float = 0.25, count: Int = 1_600) -> AudioSegment {
        AudioSegment(channel: channel, sequence: seq, startMs: start, sampleRate: 16_000,
                     samples: (0..<count).map { fill + Float($0) * 0.0001 })
    }

    func testRoundTripAndPermissions() throws {
        let spool = try AudioSpool(root: root, meetingID: "meeting-1", key: key)
        let s = segment(.microphone, 0, start: 5_000)
        try spool.append(s)
        XCTAssertEqual(try spool.read(.microphone, sequence: 0), s)
        let file = spool.directory.appendingPathComponent("mic-00000000.seg")
        let attrs = try FileManager.default.attributesOfItem(atPath: file.path)
        XCTAssertEqual((attrs[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        let dirAttrs = try FileManager.default.attributesOfItem(atPath: spool.directory.path)
        XCTAssertEqual((dirAttrs[.posixPermissions] as? NSNumber)?.intValue, 0o700)
        XCTAssertEqual(try spool.directory.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup, true)
    }

    func testNothingOnDiskIsPlainAudio() throws {
        let spool = try AudioSpool(root: root, meetingID: "meeting-1", key: key)
        let samples = [Float](repeating: 0.5, count: 4_000)
        try spool.append(AudioSegment(channel: .system, sequence: 0, startMs: 0, sampleRate: 16_000, samples: samples))
        let bytes = try Data(contentsOf: spool.directory.appendingPathComponent("sys-00000000.seg"))
        let pattern = withUnsafeBytes(of: Float(0.5)) { Data($0) }
        XCTAssertNil(bytes.range(of: pattern + pattern + pattern + pattern))
    }

    func testTamperedSwappedOrForeignSegmentsDoNotOpen() throws {
        let spool = try AudioSpool(root: root, meetingID: "meeting-1", key: key)
        try spool.append(segment(.microphone, 0, fill: 0.1))
        try spool.append(segment(.microphone, 1, fill: 0.2))
        try spool.append(segment(.system, 0, fill: 0.3))
        let dir = spool.directory
        func path(_ n: String) -> URL { dir.appendingPathComponent(n) }

        // one flipped byte
        var bytes = try Data(contentsOf: path("mic-00000000.seg"))
        bytes[bytes.count / 2] ^= 0x01
        try bytes.write(to: path("mic-00000000.seg"))
        XCTAssertThrowsError(try spool.read(.microphone, sequence: 0)) { XCTAssertEqual($0 as? SpoolError, .authenticationFailed(file: "mic-00000000.seg")) }

        // reordered: segment 1's bytes under segment 5's name
        try FileManager.default.copyItem(at: path("mic-00000001.seg"), to: path("mic-00000005.seg"))
        XCTAssertThrowsError(try spool.read(.microphone, sequence: 5))

        // moved across channels
        try FileManager.default.copyItem(at: path("sys-00000000.seg"), to: path("mic-00000002.seg"))
        XCTAssertThrowsError(try spool.read(.microphone, sequence: 2))

        // moved into another meeting that uses the same key
        let other = try AudioSpool(root: root, meetingID: "meeting-2", key: key)
        try FileManager.default.copyItem(at: path("mic-00000001.seg"), to: other.directory.appendingPathComponent("mic-00000001.seg"))
        XCTAssertThrowsError(try other.read(.microphone, sequence: 1))

        // right file, wrong key
        let wrongKey = try AudioSpool(root: root, meetingID: "meeting-1", key: SymmetricKey(size: .bits256))
        XCTAssertThrowsError(try wrongKey.read(.microphone, sequence: 1))
        XCTAssertNoThrow(try spool.read(.microphone, sequence: 1))
    }

    func testRecoveryAfterAKillMidWrite() throws {
        let spool = try AudioSpool(root: root, meetingID: "meeting-1", key: key)
        for i in 0..<4 { try spool.append(segment(.microphone, i, start: Int64(i) * 100, count: 1_600)) }
        try spool.append(segment(.system, 0, start: 0, count: 1_600))
        try spool.append(segment(.system, 2, start: 200, count: 1_600))            // sequence 1 never landed
        // what a kill leaves behind: a half-written temporary file and a truncated final file
        try Data([1, 2, 3]).write(to: spool.directory.appendingPathComponent(".tmp-mic-00000004.seg"))
        let full = try Data(contentsOf: spool.directory.appendingPathComponent("mic-00000003.seg"))
        try full.prefix(full.count / 2).write(to: spool.directory.appendingPathComponent("mic-00000003.seg"))

        let reopened = try AudioSpool(root: root, meetingID: "meeting-1", key: key)   // "next launch"
        let r = reopened.recover()
        XCTAssertEqual(r.removedTemporaryFiles, 1)
        XCTAssertEqual(r.readable[.microphone], [0, 1, 2])
        XCTAssertEqual(r.unreadable, ["mic-00000003.seg"])
        XCTAssertEqual(r.readable[.system], [0, 2])
        XCTAssertEqual(r.missing[.system], [1])
        XCTAssertEqual(r.lastAudioEndMs, 300)            // mic 2 ends at 300 ms, system 2 ends at 300 ms
        XCTAssertFalse(FileManager.default.fileExists(atPath: reopened.directory.appendingPathComponent(".tmp-mic-00000004.seg").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: reopened.directory.appendingPathComponent("mic-00000003.seg").path))  // reported, not deleted
    }

    func testMeetingIDCannotEscapeTheSpoolDirectory() {
        for bad in ["", "../other", "a/b", "meeting 1", String(repeating: "x", count: 81)] {
            XCTAssertThrowsError(try AudioSpool(root: root, meetingID: bad, key: key)) { XCTAssertEqual($0 as? SpoolError, .badMeetingID) }
        }
        XCTAssertThrowsError(try AudioSpool(root: root, meetingID: "ok", key: SymmetricKey(size: .bits128)))
    }
}

final class ResamplerTests: XCTestCase {
    func testDownsamplesStereo48kToMono16kAndKeepsTheTone() throws {
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2))
        let resampler = try XCTUnwrap(Resampler(inputFormat: format))
        var out: [Float] = []
        var phase = 0.0
        for _ in 0..<10 {                                   // ten 100 ms buffers of a 440 Hz tone
            let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4_800))
            buffer.frameLength = 4_800
            for i in 0..<4_800 {
                let v = Float(sin(phase) * 0.5)
                buffer.floatChannelData![0][i] = v
                buffer.floatChannelData![1][i] = v
                phase += 2 * .pi * 440 / 48_000
            }
            out += resampler.convert(buffer)
        }
        // One second at 16 kHz. The converter holds back a short tail (its filter delay) until more input
        // arrives, so the total is a little under; nothing is lost between buffers.
        XCTAssertEqual(Double(out.count), 16_000, accuracy: 400)
        let steady = out.dropFirst(2_000)
        let crossings = zip(steady, steady.dropFirst()).filter { $0 < 0 && $1 >= 0 }.count
        let seconds = Double(steady.count) / 16_000
        XCTAssertEqual(Double(crossings) / seconds, 440, accuracy: 8)
        XCTAssertEqual(Double(steady.map { abs($0) }.max() ?? 0), 0.5, accuracy: 0.08)
    }
}

final class MeetingKeyStoreTests: XCTestCase {
    func testCreateLoadDestroy() throws {
        let store = MeetingKeyStore(service: "com.jackzoppa.devicestudio.tests." + UUID().uuidString)
        let id = "meeting-" + UUID().uuidString
        defer { try? store.destroy(for: id) }
        let key = try store.create(for: id)
        XCTAssertEqual(try store.load(for: id).withUnsafeBytes { Data($0) }, key.withUnsafeBytes { Data($0) })
        XCTAssertThrowsError(try store.create(for: id))               // never silently replaced
        try store.destroy(for: id)
        XCTAssertThrowsError(try store.load(for: id)) { XCTAssertEqual($0 as? KeyStoreError, .missing) }
        XCTAssertNoThrow(try store.destroy(for: id))                  // destroying twice is fine
    }
}

final class EchoPolicyTests: XCTestCase {
    func testWhenOnSpeakersLeavesHeadphonesAlone() {
        XCTAssertFalse(EchoCancellation.whenOnSpeakers.enabled(for: .headphones))
        XCTAssertTrue(EchoCancellation.whenOnSpeakers.enabled(for: .speakers))
        XCTAssertTrue(EchoCancellation.whenOnSpeakers.enabled(for: .unknown))
        XCTAssertFalse(EchoCancellation.off.enabled(for: .speakers))
        XCTAssertTrue(EchoCancellation.always.enabled(for: .headphones))
    }

    func testCurrentRouteIsReadable() {
        _ = OutputRoute.current()     // must not crash on a machine with or without an output device
    }
}

final class TranscriptAssemblerTests: XCTestCase {
    func testMergeSortsByTimeAndDropsMicrophoneEcho() {
        let lines = [
            TimedText(channel: .microphone, startMs: 1_000, endMs: 4_000, text: "Can you hear me okay?"),
            TimedText(channel: .system, startMs: 5_000, endMs: 9_000, text: "Yes, the vendor quoted forty dollars for the invoice."),
            // the microphone picked up the speakers: same words, same time
            TimedText(channel: .microphone, startMs: 5_200, endMs: 9_100, text: "the vendor quoted forty dollars for the invoice"),
            TimedText(channel: .microphone, startMs: 9_500, endMs: 11_000, text: "Great, I'll pay it Friday."),
        ]
        let (merged, dropped) = TranscriptAssembler.merge(lines)
        XCTAssertEqual(dropped, 1)
        XCTAssertEqual(merged.map(\.startMs), [1_000, 5_000, 9_500])
        XCTAssertEqual(TranscriptAssembler.render(merged),
                       "[0:01] Me: Can you hear me okay?\n[0:05] Others: Yes, the vendor quoted forty dollars for the invoice.\n[0:09] Me: Great, I'll pay it Friday.\n")
    }

    func testSimilarWordsAtADifferentTimeAreNotEcho() {
        let lines = [
            TimedText(channel: .system, startMs: 0, endMs: 3_000, text: "upgrade the plan by Friday"),
            TimedText(channel: .microphone, startMs: 60_000, endMs: 63_000, text: "upgrade the plan by Friday"),
        ]
        XCTAssertEqual(TranscriptAssembler.merge(lines).echoesDropped, 0)
        XCTAssertEqual(TranscriptAssembler.render([TimedText(channel: .system, startMs: 3_725_000, endMs: 3_726_000, text: "x")]),
                       "[1:02:05] Others: x\n")
    }
}

final class SealedFileTests: XCTestCase {
    func testSealedFilesRoundTripAndAreBoundToMeetingAndKind() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("sealed-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let key = SymmetricKey(size: .bits256)
        let a = try AudioSpool(root: root, meetingID: "m-a", key: key)
        try a.writeSealed("transcript", Data("hello".utf8))
        XCTAssertEqual(try a.readSealed("transcript"), Data("hello".utf8))
        XCTAssertNil(try a.readSealed("notes"))
        let onDisk = try Data(contentsOf: a.meetingDirectory.appendingPathComponent("transcript.sealed"))
        XCTAssertNil(onDisk.range(of: Data("hello".utf8)))
        // renamed to another kind, or copied to another meeting: refused
        try FileManager.default.copyItem(at: a.meetingDirectory.appendingPathComponent("transcript.sealed"),
                                         to: a.meetingDirectory.appendingPathComponent("notes.sealed"))
        XCTAssertThrowsError(try a.readSealed("notes"))
        let b = try AudioSpool(root: root, meetingID: "m-b", key: key)
        try FileManager.default.copyItem(at: a.meetingDirectory.appendingPathComponent("transcript.sealed"),
                                         to: b.meetingDirectory.appendingPathComponent("transcript.sealed"))
        XCTAssertThrowsError(try b.readSealed("transcript"))
        XCTAssertThrowsError(try a.writeSealed("../x", Data()))
    }

    func testReadableSegmentsSkipsDamage() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("segs-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let spool = try AudioSpool(root: root, meetingID: "m-1", key: SymmetricKey(size: .bits256))
        for i in 0..<3 {
            try spool.append(AudioSegment(channel: .microphone, sequence: i, startMs: Int64(i) * 5_000, sampleRate: 16_000, samples: [0.1, 0.2]))
        }
        try Data([0]).write(to: spool.directory.appendingPathComponent("mic-00000001.seg"))
        XCTAssertEqual(spool.readableSegments(.microphone).map(\.sequence), [0, 2])
        XCTAssertEqual(spool.readableSegments(.system), [])
    }

    // MARK: Speaker names

    func testSpeakerTimelineNamesLinesByCaptionWords() {
        var timeline = SpeakerTimeline()
        timeline.add(speaker: "Dana Ruiz", text: "we should move the launch", atMs: 10_500)
        timeline.add(speaker: "Dana Ruiz", text: "we should move the launch to March", atMs: 11_500)
        timeline.add(speaker: "Sam Lee", text: "I can take the pricing page", atMs: 12_000)
        timeline.add(speaker: "You", text: "sounds good", atMs: 12_500)
        let dana = TimedText(channel: .system, startMs: 9_000, endMs: 11_000, text: "We should move the launch to March.")
        let sam = TimedText(channel: .system, startMs: 11_200, endMs: 12_100, text: "I can take the pricing page.")
        let me = TimedText(channel: .microphone, startMs: 12_000, endMs: 12_400, text: "Sounds good.")
        let far = TimedText(channel: .system, startMs: 60_000, endMs: 61_000, text: "Anything else?")
        let named = timeline.label([dana, sam, me, far])
        XCTAssertEqual(named.map(\.speaker), ["Dana Ruiz", "Sam Lee", nil, nil])
        XCTAssertEqual(named.map(\.label), ["Dana Ruiz", "Sam Lee", "Me", "Others"])
        XCTAssertEqual(timeline.names, ["Dana Ruiz", "Sam Lee"])            // "You" is never a remote speaker
    }

    func testSpeakerTimelineFallsBackToMostCaptioned() {
        var timeline = SpeakerTimeline()
        timeline.add(speaker: "Ana", text: "uh", atMs: 5_000)
        timeline.add(speaker: "Ben", text: "hmm", atMs: 5_200)
        timeline.add(speaker: "Ben", text: "hmm right", atMs: 5_400)
        let line = TimedText(channel: .system, startMs: 4_000, endMs: 5_000, text: "Totally different words")
        XCTAssertEqual(timeline.speaker(for: line), "Ben")
        // out-of-order arrival is kept sorted
        timeline.add(speaker: "Cy", text: "early bird", atMs: 1_000)
        XCTAssertEqual(timeline.captions.map(\.atMs), [1_000, 5_000, 5_200, 5_400])
        XCTAssertEqual(timeline.speaker(for: TimedText(channel: .system, startMs: 0, endMs: 900, text: "early bird")), "Cy")
    }

    func testSpeakerNamesRenderSafely() {
        XCTAssertNil(TimedText.cleanName("Me"))
        XCTAssertNil(TimedText.cleanName("  others "))
        XCTAssertNil(TimedText.cleanName(""))
        XCTAssertEqual(TimedText.cleanName("Dr: Who\nX"), "Dr Who X")
        let line = TimedText(channel: .system, startMs: 61_000, endMs: 62_000, text: "Hi.", speaker: "Dana: Ruiz")
        XCTAssertEqual(TranscriptAssembler.render([line]), "[1:01] Dana Ruiz: Hi.\n")
        let mine = TimedText(channel: .microphone, startMs: 0, endMs: 1, text: "Hey.", speaker: "Dana")
        XCTAssertEqual(TranscriptAssembler.render([mine]), "[0:00] Me: Hey.\n")
    }
}
