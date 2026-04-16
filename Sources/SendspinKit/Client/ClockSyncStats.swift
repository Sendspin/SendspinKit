// ABOUTME: Public diagnostics snapshot from the clock synchronization filter
// ABOUTME: Exposed via SendspinClient.currentClockSyncStats() for telemetry and debugging

import Foundation

/// Qualitative bucket for clock sync quality, derived from ``ClockSyncStats/estimatedError``.
///
/// Thresholds are practical targets for LAN audio sync:
/// - ``excellent`` (<5 μs): better than a typical audio frame at 48 kHz (~20 μs per sample)
/// - ``good`` (<20 μs): well within the ~1 ms perceptible threshold
/// - ``fair`` (<100 μs): acceptable for most use cases, slight drift possible
/// - ``poor`` (≥100 μs): noticeable sync errors likely
/// - ``unknown``: filter has no estimated error yet (should never happen for a
///   populated snapshot — included only for total exhaustiveness).
public enum ClockSyncQuality: String, Sendable, Hashable, Codable, CaseIterable {
    case excellent
    case good
    case fair
    case poor
    case unknown

    /// Exclusive upper bound on estimated error (μs) for each quality tier.
    /// A value strictly less than the threshold qualifies for that tier.
    /// `.poor` is the catch-all above the highest threshold and has no bound.
    public static let excellentUpperBound: Double = 5
    public static let goodUpperBound: Double = 20
    public static let fairUpperBound: Double = 100

    /// Classify an estimated error (μs) into a quality tier.
    public static func classify(estimatedError: Double?) -> ClockSyncQuality {
        guard let err = estimatedError else { return .unknown }
        switch err {
        case ..<excellentUpperBound: return .excellent
        case ..<goodUpperBound: return .good
        case ..<fairUpperBound: return .fair
        default: return .poor
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
    /// recent sample was accepted.
    public let rawRtt: Int64

    /// Drift rate (dimensionless, microseconds per microsecond).
    /// Represents how fast the offset is changing over time.
    public let drift: Double

    /// Estimated standard deviation of the offset in microseconds.
    ///
    /// Populated after the first accepted sample — it is only `nil` before
    /// any `server/time` response has been processed. Note that the library
    /// never returns a ``ClockSyncStats`` with `estimatedError == nil`: if
    /// no sample has been accepted, ``SendspinClient/currentClockSyncStats()``
    /// returns `nil` instead. The optional is kept only because the underlying
    /// filter type models the pre-sample case.
    public let estimatedError: Double?

    /// Total number of samples accepted by the filter since connect (unbounded).
    public let sampleCount: Int64

    /// Qualitative bucket derived from ``estimatedError``. See ``ClockSyncQuality``
    /// for thresholds. This is a convenience computed property — applications that
    /// want custom thresholds should ignore it and read ``estimatedError`` directly.
    public var quality: ClockSyncQuality {
        ClockSyncQuality.classify(estimatedError: estimatedError)
    }
}
