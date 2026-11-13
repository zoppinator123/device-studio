import CryptoKit
import Foundation

public enum SpoolError: Error, Equatable {
    case badMeetingID
    case cannotCreateDirectory
    case writeFailed(String)
    /// The file did not open under this meeting's key with this channel and sequence number. It was
    /// tampered with, truncated, renamed, or belongs to another meeting.
    case authenticationFailed(file: String)
    case malformed(file: String)
}

/// Encrypted, crash-safe audio spool for one meeting.
///
/// * Every segment is sealed with AES-256-GCM under the meeting's own 256-bit key (CryptoKit only).
/// * The associated data binds a segment to its meeting id, channel and sequence number, so a segment
///   cannot be moved to another meeting, another channel or another position without failing to open.
/// * A segment is written to a temporary name, flushed to the drive with F_FULLFSYNC (a plain fsync does
///   not force the flush on macOS), renamed into place, and the directory is flushed too. A power cut can
///   therefore lose the segment being written, never one that `append` already returned from.
/// * Directory 0700, files 0600, excluded from backups: the key is device-bound and short-lived, so a backup
///   would only ever hold ciphertext that cannot be opened.
///
/// Where the meeting key itself is kept (Keychain, Secure Enclave wrapping) is the store's job (M4). This
/// type takes the key it is given and never writes it anywhere.
public final class AudioSpool {
    public let directory: URL
    public let meetingID: String
    private let key: SymmetricKey
    private static let version = "devicestudio.spool.v1"
    private static let headerBytes = 16   // Int64 startMs, UInt32 sampleRate, UInt32 sampleCount

    public init(root: URL, meetingID: String, key: SymmetricKey) throws {
        // The id becomes a directory name and part of the authenticated data: keep it to a safe alphabet.
        guard !meetingID.isEmpty, meetingID.count <= 80,
              meetingID.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") }) else {
            throw SpoolError.badMeetingID
        }
        guard key.bitCount == 256 else { throw SpoolError.badMeetingID }
        self.meetingID = meetingID
        self.key = key
        var dir = root.appendingPathComponent(meetingID, isDirectory: true).appendingPathComponent("audio", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: dir.path)
            try FileManager.default.setAttributes([.posixPermissions: 0o700],
                                                  ofItemAtPath: dir.deletingLastPathComponent().path)
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            try dir.setResourceValues(values)
        } catch {
            throw SpoolError.cannotCreateDirectory
        }
        self.directory = dir
    }

    // MARK: Writing

    /// Seal one segment and make it durable. Returns only after the bytes and the directory entry are on disk.
    public func append(_ segment: AudioSegment) throws {
        var plain = Data(capacity: Self.headerBytes + segment.samples.count * 4)
        withUnsafeBytes(of: segment.startMs.littleEndian) { plain.append(contentsOf: $0) }
        withUnsafeBytes(of: UInt32(segment.sampleRate).littleEndian) { plain.append(contentsOf: $0) }
        withUnsafeBytes(of: UInt32(segment.samples.count).littleEndian) { plain.append(contentsOf: $0) }
        segment.samples.withUnsafeBufferPointer { plain.append(Data(buffer: $0)) }   // arm64 and x86_64 are little-endian

        let sealed: Data
        do {
            let box = try AES.GCM.seal(plain, using: key, authenticating: aad(segment.channel, segment.sequence))
            guard let combined = box.combined else { throw SpoolError.writeFailed("seal") }
            sealed = combined
        } catch let e as SpoolError { throw e } catch { throw SpoolError.writeFailed("seal") }

        let name = Self.fileName(segment.channel, segment.sequence)
        let final = directory.appendingPathComponent(name)
        let temp = directory.appendingPathComponent(".tmp-" + name)
        let fd = open(temp.path, O_WRONLY | O_CREAT | O_TRUNC, 0o600)
        guard fd >= 0 else { throw SpoolError.writeFailed("open") }
        var ok = sealed.withUnsafeBytes { raw -> Bool in
            var offset = 0
            while offset < raw.count {
                let n = write(fd, raw.baseAddress! + offset, raw.count - offset)
                if n <= 0 { return false }
                offset += n
            }
            return true
        }
        ok = ok && fcntl(fd, F_FULLFSYNC) == 0
        close(fd)
        guard ok else { unlink(temp.path); throw SpoolError.writeFailed("write") }
        guard rename(temp.path, final.path) == 0 else { unlink(temp.path); throw SpoolError.writeFailed("rename") }
        let dirFD = open(directory.path, O_RDONLY)
        if dirFD >= 0 { _ = fcntl(dirFD, F_FULLFSYNC); close(dirFD) }
    }

    // MARK: Reading

    /// Open one segment. Throws `authenticationFailed` unless the file is exactly what `append` wrote for
    /// this meeting, channel and sequence number.
    public func read(_ channel: CaptureChannel, sequence: Int) throws -> AudioSegment {
        let name = Self.fileName(channel, sequence)
        guard let sealed = try? Data(contentsOf: directory.appendingPathComponent(name)) else {
            throw SpoolError.malformed(file: name)
        }
        guard let box = try? AES.GCM.SealedBox(combined: sealed),
              let plain = try? AES.GCM.open(box, using: key, authenticating: aad(channel, sequence)) else {
            throw SpoolError.authenticationFailed(file: name)
        }
        guard plain.count >= Self.headerBytes else { throw SpoolError.malformed(file: name) }
        let startMs = plain.withUnsafeBytes { Int64(littleEndian: $0.loadUnaligned(fromByteOffset: 0, as: Int64.self)) }
        let rate = plain.withUnsafeBytes { UInt32(littleEndian: $0.loadUnaligned(fromByteOffset: 8, as: UInt32.self)) }
        let count = plain.withUnsafeBytes { UInt32(littleEndian: $0.loadUnaligned(fromByteOffset: 12, as: UInt32.self)) }
        guard plain.count == Self.headerBytes + Int(count) * 4 else { throw SpoolError.malformed(file: name) }
        var samples = [Float](repeating: 0, count: Int(count))
        samples.withUnsafeMutableBytes { dst in
            plain.withUnsafeBytes { src in
                dst.copyMemory(from: UnsafeRawBufferPointer(rebasing: src[Self.headerBytes...]))
            }
        }
        return AudioSegment(channel: channel, sequence: sequence, startMs: startMs, sampleRate: Int(rate), samples: samples)
    }

    public struct Recovery: Equatable, Sendable {
        /// Sequence numbers present and readable, per channel, in order.
        public var readable: [CaptureChannel: [Int]] = [:]
        /// Sequence numbers missing below the highest one present.
        public var missing: [CaptureChannel: [Int]] = [:]
        /// Files that are present but do not open (tampered, truncated, or foreign).
        public var unreadable: [String] = []
        /// Half-written temporary files removed by this pass.
        public var removedTemporaryFiles = 0
        /// Meeting time at which the last readable audio ends, across channels. Nil if nothing is readable.
        public var lastAudioEndMs: Int64?
    }

    /// The launch-time pass: discard half-written files, then report exactly what survived.
    /// Nothing readable is ever deleted, and an unreadable file is reported, not removed.
    public func recover() -> Recovery {
        var result = Recovery()
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        for name in names where name.hasPrefix(".tmp-") {
            if unlink(directory.appendingPathComponent(name).path) == 0 { result.removedTemporaryFiles += 1 }
        }
        for channel in CaptureChannel.allCases {
            let present = names.compactMap { Self.sequence(from: $0, channel: channel) }.sorted()
            guard let highest = present.last else { continue }
            var good: [Int] = []
            for seq in present {
                if let segment = try? read(channel, sequence: seq) {
                    good.append(seq)
                    result.lastAudioEndMs = max(result.lastAudioEndMs ?? Int64.min, segment.startMs + segment.durationMs)
                } else {
                    result.unreadable.append(Self.fileName(channel, seq))
                }
            }
            result.readable[channel] = good
            let have = Set(present)
            result.missing[channel] = (0...highest).filter { !have.contains($0) }
        }
        return result
    }

    // MARK: Other sealed files (transcript, notes)

    /// The meeting's folder, which holds `audio/` and the sealed transcript and notes.
    public var meetingDirectory: URL { directory.deletingLastPathComponent() }

    /// Seal and durably write a small file belonging to this meeting, such as its transcript or notes. The
    /// associated data binds it to this meeting and this `kind`, so it cannot be swapped for another file.
    public func writeSealed(_ kind: String, _ data: Data) throws {
        guard !kind.isEmpty, kind.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") }) else {
            throw SpoolError.writeFailed("kind")
        }
        let box: AES.GCM.SealedBox
        do { box = try AES.GCM.seal(data, using: key, authenticating: Data("devicestudio.file.v1|\(meetingID)|\(kind)".utf8)) }
        catch { throw SpoolError.writeFailed("seal") }
        guard let sealed = box.combined else { throw SpoolError.writeFailed("seal") }
        try durableWrite(sealed, to: meetingDirectory.appendingPathComponent("\(kind).sealed"))
    }

    /// Open a file written by `writeSealed`. Nil if it does not exist.
    public func readSealed(_ kind: String) throws -> Data? {
        let url = meetingDirectory.appendingPathComponent("\(kind).sealed")
        guard let sealed = try? Data(contentsOf: url) else { return nil }
        guard let box = try? AES.GCM.SealedBox(combined: sealed),
              let plain = try? AES.GCM.open(box, using: key, authenticating: Data("devicestudio.file.v1|\(meetingID)|\(kind)".utf8)) else {
            throw SpoolError.authenticationFailed(file: url.lastPathComponent)
        }
        return plain
    }

    /// Every readable segment of one channel, in order, for transcription. Unreadable ones are skipped
    /// (the recovery pass reports them).
    public func readableSegments(_ channel: CaptureChannel) -> [AudioSegment] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        return names.compactMap { Self.sequence(from: $0, channel: channel) }.sorted()
            .compactMap { try? read(channel, sequence: $0) }
    }

    private func durableWrite(_ bytes: Data, to final: URL) throws {
        let temp = final.deletingLastPathComponent().appendingPathComponent(".tmp-" + final.lastPathComponent)
        let fd = open(temp.path, O_WRONLY | O_CREAT | O_TRUNC, 0o600)
        guard fd >= 0 else { throw SpoolError.writeFailed("open") }
        var ok = bytes.withUnsafeBytes { raw -> Bool in
            var offset = 0
            while offset < raw.count {
                let n = write(fd, raw.baseAddress! + offset, raw.count - offset)
                if n <= 0 { return false }
                offset += n
            }
            return true
        }
        ok = ok && fcntl(fd, F_FULLFSYNC) == 0
        close(fd)
        guard ok, rename(temp.path, final.path) == 0 else { unlink(temp.path); throw SpoolError.writeFailed("write") }
        let dirFD = open(final.deletingLastPathComponent().path, O_RDONLY)
        if dirFD >= 0 { _ = fcntl(dirFD, F_FULLFSYNC); close(dirFD) }
    }

    /// Remove this meeting's audio files. Destroying the meeting key is what makes the audio unrecoverable
    /// (overwriting is not reliable on an SSD); removing the files only reclaims the space.
    public func removeFiles() {
        try? FileManager.default.removeItem(at: directory)
    }

    // MARK: Internals

    private func aad(_ channel: CaptureChannel, _ sequence: Int) -> Data {
        Data("\(Self.version)|\(meetingID)|\(channel.rawValue)|\(sequence)".utf8)
    }

    static func fileName(_ channel: CaptureChannel, _ sequence: Int) -> String {
        "\(channel.rawValue)-\(String(format: "%08d", sequence)).seg"
    }

    static func sequence(from name: String, channel: CaptureChannel) -> Int? {
        let prefix = channel.rawValue + "-"
        guard name.hasPrefix(prefix), name.hasSuffix(".seg") else { return nil }
        let digits = name.dropFirst(prefix.count).dropLast(4)
        guard digits.count == 8, digits.allSatisfy(\.isNumber) else { return nil }
        return Int(digits)
    }
}
