@testable import SendspinKit
import Testing

struct UnderrunMonitorTests {
    @Test
    func noUnderrunsStaysSynchronized() {
        var monitor = UnderrunMonitor(recoveryTicks: 2)
        for _ in 0 ..< 5 {
            #expect(monitor.observe(underrunCount: 0) == .none)
        }
        #expect(monitor.isTrackingError == false)
    }

    @Test
    func firstUnderrunEntersError() {
        var monitor = UnderrunMonitor(recoveryTicks: 2)
        #expect(monitor.observe(underrunCount: 0) == .none)
        #expect(monitor.observe(underrunCount: 1) == .toError)
        #expect(monitor.isTrackingError)
    }

    @Test
    func continuedUnderrunsDoNotReemitError() {
        var monitor = UnderrunMonitor(recoveryTicks: 2)
        #expect(monitor.observe(underrunCount: 1) == .toError)
        #expect(monitor.observe(underrunCount: 2) == .none)
        #expect(monitor.observe(underrunCount: 5) == .none)
        #expect(monitor.isTrackingError)
    }

    @Test
    func recoversOnlyAfterRequiredCleanTicks() {
        var monitor = UnderrunMonitor(recoveryTicks: 2)
        #expect(monitor.observe(underrunCount: 1) == .toError)
        // One clean tick is not enough.
        #expect(monitor.observe(underrunCount: 1) == .none)
        #expect(monitor.isTrackingError)
        // Second consecutive clean tick recovers.
        #expect(monitor.observe(underrunCount: 1) == .toSynchronized)
        #expect(monitor.isTrackingError == false)
    }

    @Test
    func underrunDuringRecoveryRestartsTheCleanCount() {
        var monitor = UnderrunMonitor(recoveryTicks: 2)
        #expect(monitor.observe(underrunCount: 1) == .toError)
        #expect(monitor.observe(underrunCount: 1) == .none) // clean tick 1
        #expect(monitor.observe(underrunCount: 2) == .none) // underrun resets the count
        #expect(monitor.observe(underrunCount: 2) == .none) // clean tick 1 again
        #expect(monitor.observe(underrunCount: 2) == .toSynchronized) // clean tick 2
    }

    @Test
    func counterResetFromStreamRestartIsTreatedAsClean() {
        var monitor = UnderrunMonitor(recoveryTicks: 2)
        #expect(monitor.observe(underrunCount: 5) == .toError)
        // A new stream resets the player's underrun counter to zero.
        #expect(monitor.observe(underrunCount: 0) == .none) // clean tick 1
        #expect(monitor.observe(underrunCount: 0) == .toSynchronized) // clean tick 2
    }

    @Test
    func resetBaselineClearsErrorAndRebaselines() {
        var monitor = UnderrunMonitor(recoveryTicks: 2)
        #expect(monitor.observe(underrunCount: 10) == .toError)

        monitor.resetBaseline(underrunCount: 10)
        #expect(monitor.isTrackingError == false)

        // Re-baselined at 10: the same count is not a new underrun.
        #expect(monitor.observe(underrunCount: 10) == .none)
        // A genuine underrun after rebaselining enters error again.
        #expect(monitor.observe(underrunCount: 11) == .toError)
    }

    @Test
    func recoveryTicksParameterIsHonored() {
        var monitor = UnderrunMonitor(recoveryTicks: 4)
        #expect(monitor.observe(underrunCount: 1) == .toError)
        #expect(monitor.observe(underrunCount: 1) == .none) // 1
        #expect(monitor.observe(underrunCount: 1) == .none) // 2
        #expect(monitor.observe(underrunCount: 1) == .none) // 3
        #expect(monitor.observe(underrunCount: 1) == .toSynchronized) // 4
    }
}
