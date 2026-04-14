// ABOUTME: Process-wide monotonic clock immune to NTP slew adjustments
// ABOUTME: Provides consistent microsecond timestamps for time sync and audio scheduling

import Darwin

/// A process-wide monotonic clock using `CLOCK_MONOTONIC_RAW` on Darwin.
///
/// `CLOCK_MONOTONIC_RAW` reads the hardware oscillator directly, bypassing NTP
/// rate adjustments (slew). This matters for Sendspin's Kalman time filter:
/// NTP slew changes the local clock's tick rate, which the filter misinterprets
/// as real drift between client and server. Using the raw oscillator ensures the
/// filter only sees actual hardware clock drift.
///
/// All timestamps in the system — `client/time` messages, sync error computation,
/// and playback scheduling — must use the same clock source for consistency.
/// The Kalman filter math is clock-source-agnostic; it only requires that all
/// local timestamps come from the same monotonic source.
///
/// The `epochAnchorMicroseconds` offset converts process-relative timestamps to
/// Unix epoch time. It's captured once at process start and used by
/// `ClockSynchronizer` and `TimeFilterSnapshot` for absolute time conversion.
/// Since it's never re-read, NTP adjustments after startup don't affect it.
enum MonotonicClock {
    /// Wall-clock epoch anchor captured once at process start.
    /// Used to convert process-relative monotonic timestamps to absolute epoch µs
    /// for `ClockSynchronizer` and `TimeFilterSnapshot`.
    ///
    /// Brackets two `CLOCK_MONOTONIC_RAW` reads around one `CLOCK_REALTIME` read
    /// and interpolates the raw pair, halving the systematic bias from scheduling
    /// delay between reads.
    static let epochAnchorMicroseconds: Int64 = {
        let raw1 = readClock(CLOCK_MONOTONIC_RAW)
        let epoch = readClock(CLOCK_REALTIME)
        let raw2 = readClock(CLOCK_MONOTONIC_RAW)
        let rawAtStart = (raw1 + raw2) / 2
        return epoch - rawAtStart
    }()

    /// Process-relative monotonic timestamp in microseconds.
    ///
    /// Uses `CLOCK_MONOTONIC_RAW` — immune to NTP slew adjustments.
    /// This is the primary clock source for all time sync operations.
    static func nowMicroseconds() -> Int64 {
        readClock(CLOCK_MONOTONIC_RAW)
    }

    /// Absolute epoch microseconds (Unix time), derived from the monotonic clock.
    ///
    /// Equivalent to `nowMicroseconds() + epochAnchorMicroseconds`. The epoch anchor
    /// is captured once at process start, so this never drifts with NTP — it's
    /// monotonic time with a fixed epoch offset.
    static func absoluteMicroseconds() -> Int64 {
        nowMicroseconds() + epochAnchorMicroseconds
    }

    // MARK: - Internal

    /// Read a POSIX clock and return microseconds.
    /// Centralizes the timespec→μs conversion to avoid duplicating the arithmetic.
    private static func readClock(_ clockID: clockid_t) -> Int64 {
        var ts = timespec()
        let rc = clock_gettime(clockID, &ts)
        assert(rc == 0, "clock_gettime failed for clock \(clockID) with errno \(errno)")
        return Int64(ts.tv_sec) * 1_000_000 + Int64(ts.tv_nsec) / 1_000
    }
}
