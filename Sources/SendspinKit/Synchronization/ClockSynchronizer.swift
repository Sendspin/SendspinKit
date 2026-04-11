// ABOUTME: Clock synchronization wrapping the 2D Kalman time filter
// ABOUTME: Handles NTP four-timestamp protocol and absolute time conversion

import Foundation

/// Quality of clock synchronization
public enum SyncQuality: Sendable {
    case good
    case degraded
    case lost
}

/// Clock synchronization statistics
public struct ClockStats: Sendable {
    public let offset: Int64
    public let rtt: Int64
    public let quality: SyncQuality
}

/// Synchronizes local clock with server clock using a 2D Kalman filter.
///
/// Wraps `SendspinTimeFilter` with:
/// - NTP four-timestamp processing (client_tx, server_rx, server_tx, client_rx)
/// - RTT gating (rejects negative and >100ms samples)
/// - Absolute time conversion (process-relative → Unix epoch for Date construction)
/// - Quality tracking
public actor ClockSynchronizer: ClockSyncProtocol {

    private var filter = SendspinTimeFilter()

    // Latest raw measurements for telemetry
    private var latestRtt: Int64 = 0
    private var quality: SyncQuality = .lost
    private var lastSyncTime: Date?

    // Absolute anchor: converts process-relative client timestamps to Unix epoch
    private let clientProcessStartAbsolute: Int64

    public init() {
        clientProcessStartAbsolute = Int64(Date().timeIntervalSince1970 * 1_000_000)
    }

    // MARK: - Public interface

    /// Current clock offset in microseconds (server - client)
    public var currentOffset: Int64 { Int64(filter.offset.rounded()) }

    /// Current sync quality
    public var currentQuality: SyncQuality { quality }

    /// Get sync statistics
    public func getStats() -> ClockStats {
        ClockStats(offset: Int64(filter.offset.rounded()), rtt: latestRtt, quality: quality)
    }

    /// Individual stats for telemetry
    public var statsOffset: Int64 { Int64(filter.offset.rounded()) }
    public var statsRtt: Int64 { latestRtt }
    public var statsQuality: SyncQuality { quality }

    /// Whether at least one sync sample has been accepted
    public var hasSynced: Bool { filter.isInitialized }

    /// Process a server/time response to update the clock model.
    ///
    /// The four timestamps follow the NTP model:
    /// - t1: client_transmitted (client clock, μs)
    /// - t2: server_received (server clock, μs)
    /// - t3: server_transmitted (server clock, μs)
    /// - t4: client_received (client clock, μs)
    public func processServerTime(
        clientTransmitted: Int64,
        serverReceived: Int64,
        serverTransmitted: Int64,
        clientReceived: Int64
    ) {
        // NTP offset and RTT calculation
        let rtt = (clientReceived - clientTransmitted) - (serverTransmitted - serverReceived)
        let measuredOffset = ((serverReceived - clientTransmitted) + (serverTransmitted - clientReceived)) / 2

        latestRtt = rtt
        lastSyncTime = Date()

        // Gate: reject invalid RTT
        guard rtt >= 0, rtt <= 100_000 else { return }

        // Feed into the Kalman filter
        let maxError = Double(max(rtt, 1)) / 2.0  // RTT floor of 1μs (Rust port fix)
        filter.update(
            timeAdded: clientReceived,
            measurement: Double(measuredOffset),
            maxError: maxError
        )

        // Update quality based on RTT
        quality = rtt < 50_000 ? .good : .degraded
    }

    /// Convert a server timestamp to local absolute time (Unix epoch μs).
    ///
    /// Server timestamps are in the server's monotonic domain (μs since server clock epoch).
    /// Returns absolute Unix epoch microseconds suitable for `Date(timeIntervalSince1970:)`.
    public func serverTimeToLocal(_ serverTime: Int64) -> Int64 {
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
    public func localTimeToServer(_ localTime: Int64) -> Int64 {
        guard filter.isInitialized else {
            return localTime - clientProcessStartAbsolute
        }

        let clientRelative = localTime - clientProcessStartAbsolute
        return filter.computeServerTime(clientRelative)
    }

    /// Check and update quality based on time since last sync
    public func checkQuality() -> SyncQuality {
        if let lastSync = lastSyncTime, Date().timeIntervalSince(lastSync) > 5.0 {
            quality = .lost
        }
        return quality
    }

    /// Reset clock synchronization (e.g., after reconnection)
    public func reset() {
        filter.reset()
        latestRtt = 0
        quality = .lost
        lastSyncTime = nil
    }
}
