import Foundation

/// Names the people on a call by matching system-audio lines to the meeting app's own captions.
///
/// The meeting app (Google Meet, through the browser extension) shows captions with the speaker's name.
/// Each caption update is kept here with the moment it was seen, on the meeting's clock. A system-audio line
/// gets the name whose captions, seen while the line was being spoken or just after, share the most words
/// with it. Captions trail speech by a second or two, so the window reaches past the end of the line.
/// Nothing here is written to disk.
public struct SpeakerTimeline: Codable, Sendable {
    public struct Caption: Codable, Equatable, Sendable {
        public var speaker: String
        public var text: String
        public var atMs: Int64
        public init(speaker: String, text: String, atMs: Int64) { self.speaker = speaker; self.text = text; self.atMs = atMs }
    }

    /// How far before a line's start and after its end a caption still counts.
    public var leadMs: Int64 = 2_000
    public var trailMs: Int64 = 3_000
    public private(set) var captions: [Caption] = []
    /// Everyone named so far, in the order first seen.
    public private(set) var names: [String] = []

    public init() {}

    public var latestMs: Int64 { captions.last?.atMs ?? 0 }

    /// Add one caption update. Captions with no usable name (including the user's own, shown as "You")
    /// are ignored: the microphone channel already covers the user.
    public mutating func add(speaker: String, text: String, atMs: Int64) {
        guard let name = TimedText.cleanName(speaker), !text.isEmpty else { return }
        let caption = Caption(speaker: name, text: text, atMs: atMs)
        // Kept sorted by time; updates almost always arrive in order.
        if let last = captions.last, last.atMs > atMs {
            let index = captions.firstIndex { $0.atMs > atMs } ?? captions.endIndex
            captions.insert(caption, at: index)
        } else {
            captions.append(caption)
        }
        note(name)
    }

    /// Add a name from the meeting's participant list.
    public mutating func note(_ raw: String) {
        guard let name = TimedText.cleanName(raw), !names.contains(name) else { return }
        names.append(name)
    }

    /// The name for one line, or nil when the captions say nothing about it.
    public func speaker(for line: TimedText) -> String? {
        guard line.channel == .system, !captions.isEmpty else { return nil }
        let from = line.startMs - leadMs, to = line.endMs + trailMs
        let lo = firstIndex(atOrAfter: from)
        guard lo < captions.endIndex, captions[lo].atMs <= to else { return nil }
        let lineWords = Set(TranscriptAssembler.words(line.text))
        var overlap: [String: Int] = [:], seen: [String: Int] = [:]
        var order: [String] = []
        for caption in captions[lo...] {
            if caption.atMs > to { break }
            if seen[caption.speaker] == nil { order.append(caption.speaker) }
            seen[caption.speaker, default: 0] += 1
            let shared = Set(TranscriptAssembler.words(caption.text)).intersection(lineWords).count
            overlap[caption.speaker] = max(overlap[caption.speaker] ?? 0, shared)
        }
        // Best word overlap wins; with no overlap at all, whoever was captioned most in the window.
        return order.max { a, b in
            let (oa, ob) = (overlap[a] ?? 0, overlap[b] ?? 0)
            if oa != ob { return oa < ob }
            if seen[a]! != seen[b]! { return seen[a]! < seen[b]! }
            return order.firstIndex(of: a)! > order.firstIndex(of: b)!   // earlier first seen wins a tie
        }
    }

    /// Name every system-audio line that the captions cover. Lines already named keep their name unless
    /// `overwrite` is set.
    public func label(_ lines: [TimedText], overwrite: Bool = true) -> [TimedText] {
        lines.map { line in
            guard line.channel == .system, overwrite || line.speaker == nil, let name = speaker(for: line) else { return line }
            var named = line
            named.speaker = name
            return named
        }
    }

    private func firstIndex(atOrAfter ms: Int64) -> Int {
        var lo = 0, hi = captions.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if captions[mid].atMs < ms { lo = mid + 1 } else { hi = mid }
        }
        return lo
    }
}
