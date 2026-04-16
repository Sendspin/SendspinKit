// ABOUTME: Public diagnostics snapshot from the clock synchronization filter
// ABOUTME: Exposed via SendspinClient.currentClockSyncStats() for telemetry and debugging

import Foundation

/// Qualitative bucket for clock sync quality, derived from ``ClockSyncStats/estimatedError``.
///
/// Thresholds are calibrated against human perception of inter-device audio
/// sync (the actual product concern), not against audio-sample-rate scheduling
/// precision. The Haas-effect fusion limit is ~35 ms; anything below 20 ms is
/// essentially imperceptible for multi-room use. The ``unacceptable`` floor
/// (100 ms) aligns with the RTT gate in ``ClockSynchronizer``, which rejects
/// samples above 100 ms RTT entirely — if ``estimatedError`` exceeds that,
/// the filter is producing an estimate looser than what the library considers
/// a usable single sample.
///
/// - ``excellent`` (<5 ms): well below any perceptual threshold
/// - ``good`` (<20 ms): below the Haas fusion limit; inaudible in practice
/// - ``fair`` (<50 ms): approaching detectable; OK for casual listening
/// - ``poor`` (<100 ms): audible offset likely on careful listening
/// - ``unacceptable`` (≥100 ms): worse than any single sample the RTT gate accepts
public enum ClockSyncQuality: String, Sendable, Hashable, Codable, CaseIterable {
    case excellent
    case good
    case fair
    case poor
    case unacceptable

    /// Exclusive upper bound on estimated error for each quality tier, in
    /// microseconds. A value strictly less than the threshold qualifies for
    /// that tier. ``unacceptable`` is the catch-all above the highest threshold
    /// and has no bound.
    ///
    /// These constants are compared against ``ClockSyncStats/estimatedError``,
    /// which is a standard deviation in microseconds. Threshold type matches
    /// the value type (`Double`) to avoid rounding mid-comparison.
    public static let excellentUpperBound: Double = 5_000 // 5 ms
    public static let goodUpperBound: Double = 20_000 // 20 ms
    public static let fairUpperBound: Double = 50_000 // 50 ms
    public static let poorUpperBound: Double = 100_000 // 100 ms (= RTT gate)

    /// Classify an estimated error (μs) into a quality tier.
    public static func classify(estimatedError: Double) -> ClockSyncQuality {
        switch estimatedError {
        case ..<excellentUpperBound: .excellent
        case ..<goodUpperBound: .good
        case ..<fairUpperBound: .fair
        case ..<poorUpperBound: .poor
        default: .unacceptable
        }
    }
}

/// Snapshot of clock synchronization state from the Kalman filter.
///
/// All time values are in microseconds unless otherwise noted.
/// Use ``SendspinClient/currentClockSyncStats()`` to obtain a snapshot.
public struct ClockSyncStats: Sendable, Hashable, Codable {
    /// Clock offset in microseconds (server_time − client_time).
    /// Positive means the server clock is ahead of the client.
    public let offset: Int64

    /// Round-trip time of the most recent **accepted** sample in microseconds.
    /// Only samples with RTT ≥ 0 and ≤ 100 ms are accepted.
    public let rtt: Int64

    /// Round-trip time of the most recent sample, including samples rejected
    /// by the RTT gate. Useful for spotting connectivity spikes that the gate
    /// would otherwise hide from telemetry. Equal to ``rtt`` when the most
    /// recent sample was accepted — use ``rawRttWasRejected`` to disambiguate
    /// a coincidental equal value from an accepted sample.
    public let rawRtt: Int64

    /// `true` when the most recent sample was rejected by the RTT gate (and
    /// therefore did not update the filter). When `true`, ``rawRtt`` reflects
    /// the rejected sample while ``rtt`` still holds the last accepted value.
    public let rawRttWasRejected: Bool

    /// Drift rate (dimensionless, microseconds per microsecond).
    /// Represents how fast the offset is changing over time.
    public let drift: Double

    /// Estimated standard deviation of the offset in microseconds.
    ///
    /// Always populated in a returned ``ClockSyncStats`` — if no sample has
    /// been accepted, ``SendspinClient/currentClockSyncStats()`` returns `nil`
    /// instead of a stats value with a missing error estimate.
    public let estimatedError: Double

    /// Total number of samples accepted by the filter since connect (unbounded).
    public let sampleCount: Int64

    /// Qualitative bucket derived from ``estimatedError``. See ``ClockSyncQuality``
    /// for thresholds. This is a convenience computed property — applications that
    /// want custom thresholds should ignore it and read ``estimatedError`` directly.
    public var quality: ClockSyncQuality {
        ClockSyncQuality.classify(estimatedError: estimatedError)
    }
}
