import Foundation

/// One clock for both channels. Every buffer is stamped with its Core Audio host time; meeting
/// time is derived from that, never from counting samples, so device drift cannot skew the channels against
/// each other and a real gap (device change, sleep, tap restart) shows up as a gap.
public struct HostClock: Sendable {
    public let startHostTime: UInt64
    private let numer: UInt64
    private let denom: UInt64

    /// `timebase` is injectable for tests; production uses the machine's.
    public init(startHostTime: UInt64, timebase: (numer: UInt32, denom: UInt32)? = nil) {
        self.startHostTime = startHostTime
        if let timebase {
            numer = UInt64(timebase.numer); denom = UInt64(timebase.denom)
        } else {
            var info = mach_timebase_info_data_t()
            mach_timebase_info(&info)
            numer = UInt64(info.numer); denom = UInt64(info.denom)
        }
    }

    public static func now() -> UInt64 { mach_absolute_time() }

    /// Milliseconds since the meeting started. Negative for a buffer stamped before the start.
    public func milliseconds(for hostTime: UInt64) -> Int64 {
        let forward = hostTime >= startHostTime
        let ticks = forward ? hostTime - startHostTime : startHostTime - hostTime
        // 128-bit intermediate: ticks * numer overflows 64 bits after a few hours on some timebases.
        let (high, low) = ticks.multipliedFullWidth(by: numer)
        let nanos = (denom * 1_000_000).dividingFullWidth((high, low)).quotient
        return forward ? Int64(nanos) : -Int64(nanos)
    }
}
