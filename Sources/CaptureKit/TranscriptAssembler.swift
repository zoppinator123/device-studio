import Foundation

/// One stretch of recognised speech on one channel.
public struct TimedText: Equatable, Sendable {
    public var channel: CaptureChannel
    public var startMs: Int64
    public var endMs: Int64
    public var text: String
    /// Who said it, when known (from the meeting app's captions). Nil means "Me" or "Others" by channel.
    public var speaker: String?
    public init(channel: CaptureChannel, startMs: Int64, endMs: Int64, text: String, speaker: String? = nil) {
        self.channel = channel; self.startMs = startMs; self.endMs = endMs; self.text = text; self.speaker = speaker
    }

    /// The label shown and written to the transcript.
    public var label: String {
        if channel == .microphone { return "Me" }
        return TimedText.cleanName(speaker) ?? "Others"
    }

    /// A name safe for the "[m:ss] Name: text" format. Labels the notes engine reserves are refused.
    public static func cleanName(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let name = raw.replacingOccurrences(of: ":", with: " ")
            .components(separatedBy: .newlines).joined(separator: " ")
            .split(separator: " ").joined(separator: " ")
        guard !name.isEmpty, name.count <= 60,
              !["me", "microphone", "others", "system audio", "you"].contains(name.lowercased()) else { return nil }
        return name
    }
}

/// Turns two channels of recognised speech into one transcript.
///
/// The channels stay attributed: the microphone is "Me", system audio is "Others". When the microphone
/// heard the call through speakers, the same words come back on both channels; a microphone line that
/// overlaps in time with a system-audio line and repeats most of its words is dropped (the text-level echo
/// safety net).
public enum TranscriptAssembler {
    public static func words(_ s: String) -> [String] {
        s.lowercased().split { !$0.isLetter && !$0.isNumber && $0 != "'" }.map(String.init)
    }

    static func isEcho(_ mic: TimedText, of system: [TimedText], threshold: Double = 0.6) -> Bool {
        let micWords = words(mic.text)
        guard micWords.count >= 3 else { return false }
        let heard = system.filter { $0.startMs < mic.endMs + 1_500 && $0.endMs > mic.startMs - 1_500 }
        guard !heard.isEmpty else { return false }
        let pool = Set(heard.flatMap { words($0.text) })
        let shared = micWords.filter { pool.contains($0) }.count
        return Double(shared) / Double(micWords.count) >= threshold
    }

    /// Merge, drop echoed microphone lines, and sort by time. Returns the lines and how many were dropped.
    public static func merge(_ lines: [TimedText]) -> (lines: [TimedText], echoesDropped: Int) {
        let system = lines.filter { $0.channel == .system }
        var dropped = 0
        let kept = lines.filter { line in
            guard line.channel == .microphone, isEcho(line, of: system) else { return true }
            dropped += 1
            return false
        }
        let sorted = kept.enumerated().sorted { a, b in
            a.element.startMs != b.element.startMs ? a.element.startMs < b.element.startMs : a.offset < b.offset
        }.map(\.element)
        return (sorted, dropped)
    }

    /// The transcript format the notes engine reads: "[m:ss] Me: ...", "[m:ss] Others: ..." or "[m:ss] Name: ...".
    public static func render(_ lines: [TimedText]) -> String {
        lines.map { line in
            let total = max(0, line.startMs / 1000)
            let stamp = total >= 3600 ? String(format: "%d:%02d:%02d", total / 3600, (total % 3600) / 60, total % 60)
                                      : String(format: "%d:%02d", total / 60, total % 60)
            return "[\(stamp)] \(line.label): \(line.text)"
        }.joined(separator: "\n") + (lines.isEmpty ? "" : "\n")
    }
}
