// ABOUTME: Clock synchronization wrapping the 2D Kalman time filter
// ABOUTME: Handles NTP four-timestamp protocol and absolute time conversion

import Foundation

/// Synchronizes local clock with server clock using a 2D Kalman filter.
///
/// Wraps `SendspinTimeFilter` with:
/// - NTP four-timestamp processing (client_tx, server_rx, server_tx, client_rx)
/// - RTT gating (rejects negative and >100ms samples)
/// - Absolute time conversion (process-relative → Unix epoch for Date construction)
actor ClockSynchronizer: ClockSyncProtocol {
    private var filter = SendspinTimeFilter()

    /// Latest raw measurements for telemetry
    private var latestRtt: Int64 = 0

    /// Absolute anchor: converts process-relative client timestamps to Unix epoch.
    /// Captured once from `MonotonicClock` at init — immune to NTP slew after startup.
    private let clientProcessStartAbsolute: Int64

    init() {
        // Snapshot the epoch anchor once. All subsequent time reads use
        // MonotonicClock.nowMicroseconds() (process-relative, NTP-immune).
        clientProcessStartAbsolute = MonotonicClock.absoluteMicroseconds() - MonotonicClock.nowMicroseconds()
    }

    // MARK: - Public interface

    /// Current clock offset in microseconds (server - client)
    var currentOffset: Int64 {
        Int64(filter.offset.rounded())
    }

    /// Individual stats for telemetry
    var statsOffset: Int64 {
        Int64(filter.offset.rounded())
    }

    var statsRtt: Int64 {
        latestRtt
    }

    /// Whether at least one sync sample has been accepted
    var hasSynced: Bool {
        filter.isInitialized
    }

    /// Process a server/time response to update the clock model.
    ///
    /// The four timestamps follow the NTP model:
    /// - t1: client_transmitted (client clock, μs)
    /// - t2: server_received (server clock, μs)
    /// - t3: server_transmitted (server clock, μs)
    /// - t4: client_received (client clock, μs)
    func processServerTime(
        clientTransmitted: Int64,
        serverReceived: Int64,
        serverTransmitted: Int64,
        clientReceived: Int64
    ) {
        // NTP offset and RTT calculation
        let rtt = (clientReceived - clientTransmitted) - (serverTransmitted - serverReceived)
        let measuredOffset = ((serverReceived - clientTransmitted) + (serverTransmitted - clientReceived)) / 2

        latestRtt = rtt

        // Gate: reject invalid RTT
        guard rtt >= 0, rtt <= 100_000 else { return }

        // Feed into the Kalman filter
        let maxError = Double(max(rtt, 1)) / 2.0 // RTT floor of 1μs (Rust port fix)
        filter.update(
            timeAdded: clientReceived,
            measurement: Double(measuredOffset),
            maxError: maxError
        )
    }

    /// Convert a server timestamp to local absolute time (Unix epoch μs).
    ///
    /// Server timestamps are in the server's monotonic domain (μs since server clock epoch).
    /// Returns absolute Unix epoch microseconds suitable for `Date(timeIntervalSince1970:)`.
    func serverTimeToLocal(_ serverTime: Int64) -> Int64 {
        guard filter.isInitialized else {
            // Pre-sync fallback: assume zero offset (will be wrong, but callers
            // should gate on hasSynced before using this for scheduling)
            return clientProcessStartAbsolute + serverTime
        }

        // The filter's computeClientTime converts server→client in the process-relative domain.
        // Add the absolute anchor to get Unix epoch time.
        let clientRelative = filter.computeClientTime(serverTime)
        return clientProcessStartAbsolute + clientRelative
    }

    /// Convert a local absolute time (Unix epoch μs) to a server timestamp.
    func localTimeToServer(_ localTime: Int64) -> Int64 {
        guard filter.isInitialized else {
            return localTime - clientProcessStartAbsolute
        }

        let clientRelative = localTime - clientProcessStartAbsolute
        return filter.computeServerTime(clientRelative)
    }

    /// Create an immutable snapshot of the current filter state for audio-thread use.
    /// The snapshot captures everything needed for time conversion without actor isolation.
    func snapshot() -> TimeFilterSnapshot {
        guard filter.isInitialized else {
            return .invalid
        }
        return TimeFilterSnapshot(
            offset: filter.offset,
            drift: filter.drift,
            lastUpdate: filter.lastUpdate,
            useDrift: filter.useDrift,
            clientProcessStartAbsolute: clientProcessStartAbsolute,
            isValid: true
        )
    }
}
