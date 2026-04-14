// ABOUTME: Immutable snapshot of time filter state for audio-thread-safe time conversion
// ABOUTME: Captures filter parameters so the audio callback can convert timestamps without actor hops

import Foundation

/// An immutable snapshot of the clock synchronizer's state, suitable for reading
/// from the real-time audio thread without any actor isolation or locks.
///
/// Created by `ClockSynchronizer.snapshot()` and consumed by the audio callback
/// to compute sync error with microsecond precision. The snapshot is cheap to copy
/// (6 scalars) and can be stored under any lock the audio thread already holds.
///
/// `Sendable` conformance is implicit (all stored properties are `Sendable` types,
/// internal struct) but is the essential contract of this type — it exists to cross
/// actor boundaries safely.
struct TimeFilterSnapshot {
    /// Kalman filter offset estimate (μs): server_time ≈ client_time + offset
    let offset: Double
    /// Kalman filter drift estimate (μs/μs, dimensionless)
    let drift: Double
    /// Client timestamp of the last filter update (process-relative μs)
    let lastUpdate: Int64
    /// Whether drift is statistically significant (SNR gate)
    let useDrift: Bool
    /// Unix epoch μs when the client process started — converts process-relative to absolute
    let clientProcessStartAbsolute: Int64
    /// Whether the filter has received at least one measurement
    let isValid: Bool

    /// Sentinel value for "no sync data available yet"
    static let invalid = TimeFilterSnapshot(
        offset: 0, drift: 0, lastUpdate: 0, useDrift: false,
        clientProcessStartAbsolute: 0, isValid: false
    )

    /// Convert a server timestamp to local absolute time (Unix epoch μs).
    ///
    /// This replicates the math from `ClockSynchronizer.serverTimeToLocal` and
    /// `SendspinTimeFilter.computeClientTime` without any actor isolation.
    func serverTimeToLocal(_ serverTime: Int64) -> Int64 {
        guard isValid else { return 0 }

        let effectiveDrift = useDrift ? drift : 0.0
        let numerator = Double(serverTime) - offset + effectiveDrift * Double(lastUpdate)
        let denominator = 1.0 + effectiveDrift
        let clientRelative = Int64((numerator / denominator).rounded())
        return clientProcessStartAbsolute + clientRelative
    }

    /// Convert a local absolute time (Unix epoch μs) to a server timestamp.
    ///
    /// This replicates the math from `ClockSynchronizer.localTimeToServer` and
    /// `SendspinTimeFilter.computeServerTime` without any actor isolation.
    func localToServerTime(_ localTime: Int64) -> Int64 {
        guard isValid else { return 0 }

        let clientRelative = localTime - clientProcessStartAbsolute
        let effectiveDrift = useDrift ? drift : 0.0
        let currentOffset = offset + effectiveDrift * Double(clientRelative - lastUpdate)
        return clientRelative + Int64(currentOffset.rounded())
    }
}
