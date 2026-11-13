import AVFoundation

/// Streams one source's audio to 16 kHz mono float, keeping converter state between buffers so
/// there are no clicks at buffer edges.
public final class Resampler {
    public static let outputRate = 16_000.0
    private let converter: AVAudioConverter
    private let outputFormat: AVAudioFormat
    public let inputFormat: AVAudioFormat

    public init?(inputFormat: AVAudioFormat) {
        guard let out = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: Self.outputRate, channels: 1, interleaved: false),
              let converter = AVAudioConverter(from: inputFormat, to: out) else { return nil }
        converter.downmix = true          // stereo system audio becomes one channel, not just its left side
        self.inputFormat = inputFormat
        self.outputFormat = out
        self.converter = converter
    }

    /// Returns the 16 kHz mono samples for this buffer (possibly a few fewer or more than the exact ratio,
    /// since the converter carries a fraction of a sample between calls).
    public func convert(_ buffer: AVAudioPCMBuffer) -> [Float] {
        guard buffer.frameLength > 0 else { return [] }
        let ratio = Self.outputRate / inputFormat.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 32
        guard let out = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: capacity) else { return [] }
        var supplied = false
        var error: NSError?
        let status = converter.convert(to: out, error: &error) { _, outStatus in
            if supplied { outStatus.pointee = .noDataNow; return nil }
            supplied = true
            outStatus.pointee = .haveData
            return buffer
        }
        guard status != .error, error == nil, let data = out.floatChannelData else { return [] }
        return Array(UnsafeBufferPointer(start: data[0], count: Int(out.frameLength)))
    }
}
