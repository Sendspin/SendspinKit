// ABOUTME: Clock synchronization wrapping the 2D Kalman time filter
// ABOUTME: Handles NTP four-timestamp protocol and absolute time conversion

import Foundation

/// Synchronizes local clock with server clock using a 2D Kalman filter.
///
/// Wraps `SendspinTimeFilter` with:
/// - NTP four-timestamp processing (client_tx, server_rx, server_tx, client_rx)
/// - RTT gating (rejects samples with negative or excessive round-trip times)
/// - Absolute time conversion (process-relative → Unix epoch for Date construction)
actor ClockSynchronizer: ClockSyncProtocol {
    /// Point-in-time snapshot of clock sync diagnostics, returned by ``diagnosticSnapshot()``.
    ///
    /// `rtt` is the most recent accepted RTT. `rawRtt` is the most recent RTT including
    /// samples rejected by the RTT gate — useful for spotting connectivity spikes in
    /// telemetry where the gate would otherwise hide them.
    struct DiagnosticSnapshot {
        let offset: Int64
        let rtt: Int64
        let rawRtt: Int64
        let drift: Double
        let estimatedError: Double?
        let sampleCount: Int64
    }

    // MARK: - Constants

    /// Maximum acceptable round-trip time (100ms). Samples with RTT above this
    /// are rejected as too noisy to improve the filter estimate.
    private static let maxAcceptableRttMicroseconds: Int64 = 100_000

    /// Minimum RTT used for measurement error calculation. Prevents zero-variance
    /// on localhost where RTT can be near-zero. From the Rust reference port.
    private static let rttFloorMicroseconds: Int64 = 1

    // MARK: - State

    private var filter = SendspinTimeFilter()

    /// Most recent accepted round-trip time in microseconds.
    /// Only updated when a sample passes the RTT gate.
    private(set) var latestAcceptedRtt: Int64 = 0

    /// Most recent raw round-trip time in microseconds, including rejected samples.
    /// Useful for diagnosing connectivity spikes in telemetry — shows RTT for
    /// *every* server/time response, not just those accepted by the filter.
    private(set) var latestRawRtt: Int64 = 0

    /// Total number of samples accepted by the filter (unbounded). Unlike
    /// `SendspinTimeFilter.count`, which saturates at `minSamplesForForgetting`
    /// (default 100) as an internal warmup counter, this keeps counting so
    /// telemetry can show "we've processed N accepted samples since connect."
    private(set) var totalSamplesAccepted: Int64 = 0

    /// Absolute anchor: converts process-relative client timestamps to Unix epoch.
    /// Uses `MonotonicClock.epochAnchorMicroseconds` which captures both clocks
    /// as close together as possible at process start — immune to NTP slew.
    private let clientProcessStartAbsolute: Int64

    init() {
        clientProcessStartAbsolute = MonotonicClock.epochAnchorMicroseconds
    }

    // MARK: - Public interface

    /// Current clock offset in microseconds (server - client).
    /// Used for both time conversion and telemetry reporting.
    var currentOffset: Int64 {
        Int64(filter.offset.rounded())
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

        // Always record raw RTT for spike diagnostics
        latestRawRtt = rtt

        // Gate: reject samples with negative or excessive RTT
        guard rtt >= 0, rtt <= Self.maxAcceptableRttMicroseconds else { return }

        latestAcceptedRtt = rtt

        // Feed into the Kalman filter
        let maxError = Double(max(rtt, Self.rttFloorMicroseconds)) / 2.0
        filter.update(
            timeAdded: clientReceived,
            measurement: Double(measuredOffset),
            maxError: maxError
        )
        totalSamplesAccepted &+= 1
    }

    /// Convert a server timestamp to local absolute time (Unix epoch μs).
    ///
    /// Server timestamps are in the server's monotonic domain (μs since server clock epoch).
    /// Returns absolute Unix epoch microseconds suitable for `Date(timeIntervalSince1970:)`.
    ///
    /// - Important: Before the first successful sync (`hasSynced == false`), this returns
    ///   a best-effort value assuming zero offset. Callers **must** gate on `hasSynced`
    ///   before using the result for playback scheduling. `SendspinClient` enforces this
    ///   by dropping audio chunks until `hasSynced` is true.
    func serverTimeToLocal(_ serverTime: Int64) -> Int64 {
        guard filter.isInitialized else {
            // No sync data yet — assume zero offset. This produces a value in the
            // correct absolute-time domain but with an unknown error equal to the
            // true server-client offset. Only useful as a placeholder until the
            // first sync completes.
            return clientProcessStartAbsolute + serverTime
        }

        // The filter's computeClientTime converts server→client in the process-relative domain.
        // Add the absolute anchor to get Unix epoch time.
        let clientRelative = filter.computeClientTime(serverTime)
        return clientProcessStartAbsolute + clientRelative
    }

    /// Convert a local absolute time (Unix epoch μs) to a server timestamp.
    ///
    /// - Important: Before the first successful sync, assumes zero offset.
    ///   See ``serverTimeToLocal(_:)`` for details.
    func localTimeToServer(_ localTime: Int64) -> Int64 {
        guard filter.isInitialized else {
            return localTime - clientProcessStartAbsolute
        }

        let clientRelative = localTime - clientProcessStartAbsolute
        return filter.computeServerTime(clientRelative)
    }

    /// Atomic snapshot of all diagnostic values for public telemetry.
    ///
    /// Returns offset, RTT, and filter stats in a single actor hop so callers
    /// get a consistent point-in-time view without multiple await boundaries.
    /// Returns `nil` before the first sample is accepted by the filter —
    /// callers use this as the "no data yet" signal.
    func diagnosticSnapshot() -> DiagnosticSnapshot? {
        guard filter.isInitialized else { return nil }
        return DiagnosticSnapshot(
            offset: currentOffset,
            rtt: latestAcceptedRtt,
            rawRtt: latestRawRtt,
            drift: filter.drift,
            estimatedError: filter.estimatedError,
            sampleCount: totalSamplesAccepted
        )
    }

    /// Create an immutable snapshot of the current filter state for audio-thread use.
    /// Returns `nil` before the first successful sync.
    func snapshot() -> TimeFilterSnapshot? {
        guard filter.isInitialized else { return nil }
        return TimeFilterSnapshot(
            offset: filter.offset,
            drift: filter.drift,
            lastUpdate: filter.lastUpdate,
            useDrift: filter.useDrift,
            clientProcessStartAbsolute: clientProcessStartAbsolute
        )
    }
}
