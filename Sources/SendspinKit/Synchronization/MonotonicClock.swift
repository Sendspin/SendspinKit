// ABOUTME: Process-wide monotonic clock immune to NTP slew adjustments
// ABOUTME: Provides consistent microsecond timestamps for time sync and audio scheduling

import Foundation

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
    /// Both `CLOCK_MONOTONIC_RAW` and `CLOCK_REALTIME` are read as close together
    /// as possible to minimize jitter in the anchor value.
    static let epochAnchorMicroseconds: Int64 = {
        // Capture both clocks as close together as possible
        var ts = timespec()
        clock_gettime(CLOCK_MONOTONIC_RAW, &ts)
        let rawAtStart = Int64(ts.tv_sec) * 1_000_000 + Int64(ts.tv_nsec) / 1_000

        clock_gettime(CLOCK_REALTIME, &ts)
        let epochAtStart = Int64(ts.tv_sec) * 1_000_000 + Int64(ts.tv_nsec) / 1_000

        return epochAtStart - rawAtStart
    }()

    /// Process-relative monotonic timestamp in microseconds.
    ///
    /// Uses `CLOCK_MONOTONIC_RAW` — immune to NTP slew adjustments.
    /// This is the primary clock source for all time sync operations.
    static func nowMicroseconds() -> Int64 {
        var ts = timespec()
        clock_gettime(CLOCK_MONOTONIC_RAW, &ts)
        return Int64(ts.tv_sec) * 1_000_000 + Int64(ts.tv_nsec) / 1_000
    }

    /// Absolute epoch microseconds (Unix time), derived from the monotonic clock.
    ///
    /// Equivalent to `nowMicroseconds() + epochAnchor`. The epoch anchor is captured
    /// once at process start, so this never drifts with NTP — it's monotonic time
    /// with a fixed epoch offset.
    static func absoluteMicroseconds() -> Int64 {
        nowMicroseconds() + epochAnchorMicroseconds
    }
}
