// ABOUTME: Clock synchronization diagnostics exposed by SendspinClient
// ABOUTME: Provides current server-time estimates and clock filter snapshots

import Foundation

public extension SendspinClient {
    internal nonisolated func getCurrentMicroseconds() -> Int64 {
        MonotonicClock.nowMicroseconds()
    }

    /// Estimate the current server time in microseconds.
    ///
    /// Uses the clock synchronization filter to convert the local monotonic clock
    /// to the server's clock domain. Returns `nil` if clock sync has not completed
    /// (no `server/time` responses received yet).
    ///
    /// Use this with ``PlaybackProgress/currentPositionMs(at:)`` to compute
    /// the real-time interpolated playback position:
    /// ```swift
    /// if let serverTime = await client.currentServerTimeMicroseconds(),
    ///    let progress = client.currentMetadata?.progress {
    ///     let positionMs = progress.currentPositionMs(at: serverTime)
    /// }
    /// ```
    @MainActor
    func currentServerTimeMicroseconds() async -> Int64? {
        guard let connection else { return nil }
        return await connection.currentServerTimeMicroseconds(localNow: MonotonicClock.absoluteMicroseconds())
    }

    /// Snapshot of the current clock synchronization state.
    ///
    /// Returns `nil` if the client is not connected or clock sync has not
    /// completed (no `server/time` responses accepted yet).
    ///
    /// Useful for diagnostics, telemetry dashboards, and debugging sync quality.
    /// The returned values are a point-in-time snapshot — they may change on the
    /// next `server/time` exchange.
    @MainActor
    func currentClockSyncStats() async -> ClockSyncStats? {
        guard let connection else { return nil }
        // Single actor hop through the connection — all values are from the
        // connection-owned clock-sync actor at one point in time. The connection
        // returns nil when the filter has not accepted any sample yet.
        return await connection.currentClockSyncStats()
    }
}
