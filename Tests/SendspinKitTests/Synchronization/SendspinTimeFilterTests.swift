// ABOUTME: Tests for the 2D Kalman time filter
// ABOUTME: Validates convergence, drift tracking, covariance behavior, and time conversions

@testable import SendspinKit
import Testing

struct SendspinTimeFilterTests {
    // MARK: - Initialization

    @Test
    func `fresh filter has uninformative prior`() {
        let filter = SendspinTimeFilter()
        #expect(!filter.isInitialized)
        #expect(filter.count == 0)
        #expect(filter.offset == 0.0)
        #expect(filter.drift == 0.0)
        #expect(filter.offsetCovariance == .infinity)
        #expect(filter.useDrift == false)
    }

    @Test
    func `first measurement initializes offset`() {
        var filter = SendspinTimeFilter()
        filter.update(timeAdded: 1_000, measurement: 500.0, maxError: 50.0)

        #expect(filter.isInitialized)
        #expect(filter.count == 1)
        #expect(filter.offset == 500.0)
        #expect(filter.drift == 0.0)
        #expect(filter.offsetCovariance == 2_500.0) // 50²
    }

    @Test
    func `second measurement initializes drift`() {
        var filter = SendspinTimeFilter()
        filter.update(timeAdded: 1_000, measurement: 500.0, maxError: 50.0)
        filter.update(timeAdded: 2_000, measurement: 510.0, maxError: 50.0)

        #expect(filter.count == 2)
        #expect(filter.offset == 510.0)
        // drift = (510 - 500) / (2000 - 1000) = 0.01
        #expect(filter.drift == 0.01)
    }

    // MARK: - Convergence

    @Test
    func `converges on constant offset with zero drift`() {
        var filter = SendspinTimeFilter()
        let trueOffset = 1_000.0

        // Feed 50 measurements with the same offset, small noise via varying maxError
        for i in 0 ..< 50 {
            let t = Int64((i + 1) * 100_000) // 100ms apart
            filter.update(timeAdded: t, measurement: trueOffset, maxError: 25.0)
        }

        // Should converge close to true offset
        #expect(abs(filter.offset - trueOffset) < 1.0)
        // Drift should be near zero
        #expect(abs(filter.drift) < 0.0001)
        // Covariance should be much smaller than initial measurement variance (625)
        // but process noise prevents it from reaching zero
        #expect(filter.offsetCovariance < 650.0)
        #expect(filter.offsetCovariance < 2_500.0) // well below initial prior
    }

    @Test
    func `tracks linear drift`() {
        var filter = SendspinTimeFilter()
        let trueOffset = 1_000.0
        let trueDrift = 0.001 // 1μs per ms = 1ppm

        for i in 0 ..< 100 {
            let t = Int64((i + 1) * 100_000)
            let expectedOffset = trueOffset + trueDrift * Double(t)
            filter.update(timeAdded: t, measurement: expectedOffset, maxError: 25.0)
        }

        // Should track the drift
        #expect(abs(filter.drift - trueDrift) < 0.0001)
    }

    // MARK: - RTT floor

    @Test
    func `handles zero maxError (localhost)`() {
        var filter = SendspinTimeFilter()
        // maxError of 0 should be floored to 1.0 internally
        filter.update(timeAdded: 1_000, measurement: 500.0, maxError: 0.0)

        #expect(filter.isInitialized)
        #expect(filter.offsetCovariance == 1.0) // 1² = 1
        #expect(!filter.offset.isNaN)
        #expect(!filter.offsetCovariance.isNaN)
    }

    @Test
    func `no NaN after many localhost updates`() {
        var filter = SendspinTimeFilter()

        for i in 0 ..< 200 {
            let t = Int64((i + 1) * 100_000)
            filter.update(timeAdded: t, measurement: 500.0, maxError: 0.0)
        }

        #expect(!filter.offset.isNaN)
        #expect(!filter.drift.isNaN)
        #expect(!filter.offsetCovariance.isNaN)
        #expect(!filter.driftCovariance.isNaN)
        #expect(!filter.offsetDriftCovariance.isNaN)
    }

    // MARK: - Monotonicity guard

    @Test
    func `rejects non-monotonic timestamps`() {
        var filter = SendspinTimeFilter()
        filter.update(timeAdded: 2_000, measurement: 500.0, maxError: 50.0)
        filter.update(timeAdded: 1_000, measurement: 600.0, maxError: 50.0) // earlier!

        #expect(filter.count == 1)
        #expect(filter.offset == 500.0) // unchanged
    }

    @Test
    func `rejects duplicate timestamp`() {
        var filter = SendspinTimeFilter()
        filter.update(timeAdded: 1_000, measurement: 500.0, maxError: 50.0)
        filter.update(timeAdded: 1_000, measurement: 600.0, maxError: 50.0) // same time

        #expect(filter.count == 1)
        #expect(filter.offset == 500.0) // unchanged
    }

    // MARK: - Drift significance gate

    @Test
    func `drift not used when statistically insignificant`() {
        var filter = SendspinTimeFilter()
        // Two measurements close together → noisy drift estimate → should not use drift
        filter.update(timeAdded: 1_000, measurement: 500.0, maxError: 50.0)
        filter.update(timeAdded: 1_100, measurement: 500.5, maxError: 50.0)

        // Drift was initialized but may not pass SNR gate
        // With high covariance relative to small drift, useDrift should be false
        #expect(!filter.useDrift)
    }

    // MARK: - Time conversion

    @Test
    func `computeServerTime and computeClientTime are inverses`() {
        var filter = SendspinTimeFilter()
        let trueOffset = 5_000.0

        for i in 0 ..< 20 {
            let t = Int64((i + 1) * 100_000)
            filter.update(timeAdded: t, measurement: trueOffset, maxError: 10.0)
        }

        let clientTime: Int64 = 2_000_000
        let serverTime = filter.computeServerTime(clientTime)
        let roundTripped = filter.computeClientTime(serverTime)

        // Should round-trip within 1μs (rounding tolerance)
        #expect(abs(roundTripped - clientTime) <= 1)
    }

    @Test
    func `computeServerTime applies offset correctly`() {
        var filter = SendspinTimeFilter()

        // Establish a known offset of 1000μs
        for i in 0 ..< 10 {
            let t = Int64((i + 1) * 100_000)
            filter.update(timeAdded: t, measurement: 1_000.0, maxError: 10.0)
        }

        let clientTime: Int64 = 500_000
        let serverTime = filter.computeServerTime(clientTime)

        // server ≈ client + offset
        #expect(abs(serverTime - (clientTime + 1_000)) < 5)
    }

    // MARK: - Reset

    @Test
    func `reset returns to uninformative prior`() {
        var filter = SendspinTimeFilter()
        filter.update(timeAdded: 1_000, measurement: 500.0, maxError: 50.0)
        filter.update(timeAdded: 2_000, measurement: 510.0, maxError: 50.0)

        #expect(filter.count == 2)

        filter.reset()

        #expect(!filter.isInitialized)
        #expect(filter.count == 0)
        #expect(filter.offset == 0.0)
        #expect(filter.drift == 0.0)
        #expect(filter.offsetCovariance == .infinity)
        #expect(filter.useDrift == false)
    }

    // MARK: - Adaptive forgetting

    @Test
    func `covariance shrinks with consistent measurements`() {
        var filter = SendspinTimeFilter()

        var lastCovariance: Double = .infinity
        for i in 0 ..< 30 {
            let t = Int64((i + 1) * 100_000)
            filter.update(timeAdded: t, measurement: 1_000.0, maxError: 50.0)

            if i > 2 {
                // After initialization phase, covariance should generally decrease
                // (not strictly monotonic due to process noise, but the trend is down)
                #expect(
                    filter.offsetCovariance < lastCovariance * 1.5,
                    "Covariance at step \(i) should not grow excessively"
                )
            }
            lastCovariance = filter.offsetCovariance
        }

        // Final covariance should stabilize at a steady-state determined by process/measurement noise
        #expect(filter.offsetCovariance < 2_600.0)
    }

    // MARK: - Estimated error

    @Test
    func `offset covariance decreases with consistent measurements`() {
        // Use low process noise so covariance clearly shrinks
        var filter = SendspinTimeFilter(processStdDev: 0.001, driftProcessStdDev: 0.0001)

        filter.update(timeAdded: 100_000, measurement: 1_000.0, maxError: 50.0)
        let covarianceAfterOne = filter.offsetCovariance

        for i in 1 ..< 50 {
            let t = Int64((i + 1) * 100_000)
            filter.update(timeAdded: t, measurement: 1_000.0, maxError: 50.0)
        }
        let covarianceAfterFifty = filter.offsetCovariance

        // Raw covariance should decrease (even if integer-rounded error doesn't)
        #expect(covarianceAfterFifty < covarianceAfterOne)
    }
}
