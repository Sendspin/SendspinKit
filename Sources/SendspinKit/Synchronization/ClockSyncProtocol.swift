// ABOUTME: Protocol abstracting clock synchronization for testability
// ABOUTME: Allows AudioScheduler to accept any actor that converts server timestamps

/// Protocol for clock synchronization.
///
/// Abstracts the server→local time conversion so `AudioScheduler` can be
/// tested with mock clocks. The sole production conformer is ``ClockSynchronizer``.
protocol ClockSyncProtocol: Actor {
    func serverTimeToLocal(_ serverTime: Int64) -> Int64
}
