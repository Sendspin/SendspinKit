// ABOUTME: Protocol abstracting clock synchronization for testability
// ABOUTME: Allows AudioScheduler to accept any actor that converts server timestamps

/// Protocol for clock synchronization.
///
/// Abstracts the server→local time conversion so `AudioScheduler` can be
/// tested with mock clocks. The sole production conformer is ``ClockSynchronizer``.
protocol ClockSyncProtocol: Actor {
    var hasSynced: Bool { get }

    func processServerTime(
        clientTransmitted: Int64,
        serverReceived: Int64,
        serverTransmitted: Int64,
        clientReceived: Int64
    )
    func serverTimeToLocal(_ serverTime: Int64) -> Int64
    func localTimeToServer(_ localTime: Int64) -> Int64
    func snapshot() -> TimeFilterSnapshot?
    func diagnosticSnapshot() -> ClockSynchronizer.DiagnosticSnapshot?
}
