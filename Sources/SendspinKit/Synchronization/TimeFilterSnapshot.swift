// ABOUTME: Immutable snapshot of time filter state for audio-thread-safe time conversion
// ABOUTME: Captures filter parameters so the audio callback can convert timestamps without actor hops

/// An immutable snapshot of the clock synchronizer's state, suitable for reading
/// from the real-time audio thread without any actor isolation or locks.
///
/// Created by `ClockSynchronizer.snapshot()` (returns `nil` before first sync)
/// and consumed by the audio callback to compute sync error with microsecond
/// precision. A non-nil snapshot is always valid — the type system enforces this.
///
/// Cheap to copy (5 scalars) and can be stored under any lock the audio thread
/// already holds. `Sendable` conformance is compiler-synthesized (all stored
/// properties are `Sendable` value types) — this is the essential contract of
/// the type, as it exists to cross actor boundaries safely.
struct TimeFilterSnapshot: Equatable {
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

    /// Convert a server timestamp to local absolute time (Unix epoch μs).
    ///
    /// Replicates `ClockSynchronizer.serverTimeToLocal` /
    /// `SendspinTimeFilter.computeClientTime` without actor isolation.
    func serverTimeToLocal(_ serverTime: Int64) -> Int64 {
        let effectiveDrift = useDrift ? drift : 0.0
        let numerator = Double(serverTime) - offset + effectiveDrift * Double(lastUpdate)
        let denominator = 1.0 + effectiveDrift
        let clientRelative = Int64((numerator / denominator).rounded())
        return clientProcessStartAbsolute + clientRelative
    }

    /// Convert a local absolute time (Unix epoch μs) to a server timestamp.
    ///
    /// Replicates `ClockSynchronizer.localTimeToServer` /
    /// `SendspinTimeFilter.computeServerTime` without actor isolation.
    func localTimeToServer(_ localTime: Int64) -> Int64 {
        let clientRelative = localTime - clientProcessStartAbsolute
        let effectiveDrift = useDrift ? drift : 0.0
        let currentOffset = offset + effectiveDrift * Double(clientRelative - lastUpdate)
        return clientRelative + Int64(currentOffset.rounded())
    }
}
