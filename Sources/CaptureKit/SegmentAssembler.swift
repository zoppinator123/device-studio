import Foundation

public enum CaptureChannel: String, Sendable, CaseIterable {
    case microphone = "mic"       // "Me"
    case system = "sys"           // "Others"
}

/// A run of 16 kHz mono samples that starts at a known meeting time.
public struct AudioSegment: Equatable, Sendable {
    public let channel: CaptureChannel
    public let sequence: Int
    public let startMs: Int64
    public let sampleRate: Int
    public let samples: [Float]

    public init(channel: CaptureChannel, sequence: Int, startMs: Int64, sampleRate: Int, samples: [Float]) {
        self.channel = channel; self.sequence = sequence; self.startMs = startMs
        self.sampleRate = sampleRate; self.samples = samples
    }

    public var durationMs: Int64 { Int64(samples.count) * 1000 / Int64(sampleRate) }
}

/// Cuts one channel's sample stream into spool segments (5-second sealed segments).
///
/// A buffer whose host-time stamp does not line up with the audio already held starts a new segment at its
/// own time. Later audio is therefore never shifted to fill a hole: a device change, sleep or tap restart
/// leaves a visible gap between two segments instead.
public struct SegmentAssembler {
    public let channel: CaptureChannel
    public let sampleRate: Int
    public let segmentSamples: Int
    public let gapToleranceMs: Int64

    private var buffer: [Float] = []
    private var startMs: Int64 = 0
    private var nextSequence = 0

    public init(channel: CaptureChannel, sampleRate: Int = 16_000, segmentSeconds: Double = 5, gapToleranceMs: Int64 = 150) {
        self.channel = channel
        self.sampleRate = sampleRate
        self.segmentSamples = Int(Double(sampleRate) * segmentSeconds)
        self.gapToleranceMs = gapToleranceMs
    }

    /// Where the next sample is expected to fall, given what is buffered.
    private var expectedMs: Int64 { startMs + Int64(buffer.count) * 1000 / Int64(sampleRate) }

    /// Add samples stamped with the meeting time of their first sample. Returns any segments now complete.
    public mutating func append(_ samples: [Float], atMs: Int64) -> [AudioSegment] {
        guard !samples.isEmpty else { return [] }
        var out: [AudioSegment] = []
        if buffer.isEmpty {
            startMs = atMs
        } else if abs(atMs - expectedMs) > gapToleranceMs {
            out.append(cut(count: buffer.count))
            startMs = atMs
        }
        buffer.append(contentsOf: samples)
        while buffer.count >= segmentSamples {
            out.append(cut(count: segmentSamples))
        }
        return out
    }

    /// Emit whatever is left (on Stop, or when the source restarts).
    public mutating func flush() -> AudioSegment? {
        buffer.isEmpty ? nil : cut(count: buffer.count)
    }

    private mutating func cut(count: Int) -> AudioSegment {
        let segment = AudioSegment(channel: channel, sequence: nextSequence, startMs: startMs,
                                   sampleRate: sampleRate, samples: Array(buffer.prefix(count)))
        nextSequence += 1
        buffer.removeFirst(count)
        startMs += Int64(count) * 1000 / Int64(sampleRate)
        return segment
    }
}
