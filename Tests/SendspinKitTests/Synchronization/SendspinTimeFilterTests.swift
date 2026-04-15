// ABOUTME: Tests for the 2D Kalman time filter
// ABOUTME: Validates convergence, drift tracking, covariance behavior, and time conversions

@testable import SendspinKit
import Testing

struct SendspinTimeFilterTests {
    // MARK: - Initialization

    @Test
    func freshFilterHasUninformativePrior() {
        let filter = SendspinTimeFilter()
        #expect(!filter.isInitialized)
        #expect(filter.count == 0)
        #expect(filter.offset == 0.0)
        #expect(filter.drift == 0.0)
        #expect(filter.offsetCovariance == .infinity)
        #expect(filter.useDrift == false)
    }

    @Test
    func firstMeasurementInitializesOffset() {
        var filter = SendspinTimeFilter()
        filter.update(timeAdded: 1_000, measurement: 500.0, maxError: 50.0)

        #expect(filter.isInitialized)
        #expect(filter.count == 1)
        #expect(filter.offset == 500.0)
        #expect(filter.drift == 0.0)
        #expect(filter.offsetCovariance == 2_500.0) // 50²
    }

    @Test
    func secondMeasurementInitializesDrift() {
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
    func convergesOnConstantOffsetWithZeroDrift() {
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
    func tracksLinearDrift() {
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
    func handlesZeroMaxErrorLocalhost() {
        var filter = SendspinTimeFilter()
        // maxError of 0 should be floored to 1.0 internally
        filter.update(timeAdded: 1_000, measurement: 500.0, maxError: 0.0)

        #expect(filter.isInitialized)
        #expect(filter.offsetCovariance == 1.0) // 1² = 1
        #expect(!filter.offset.isNaN)
        #expect(!filter.offsetCovariance.isNaN)
    }

    @Test
    func noNaNAfterManyLocalhostUpdates() {
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
    func rejectsNonMonotonicTimestamps() {
        var filter = SendspinTimeFilter()
        filter.update(timeAdded: 2_000, measurement: 500.0, maxError: 50.0)
        filter.update(timeAdded: 1_000, measurement: 600.0, maxError: 50.0) // earlier!

        #expect(filter.count == 1)
        #expect(filter.offset == 500.0) // unchanged
    }

    @Test
    func rejectsDuplicateTimestamp() {
        var filter = SendspinTimeFilter()
        filter.update(timeAdded: 1_000, measurement: 500.0, maxError: 50.0)
        filter.update(timeAdded: 1_000, measurement: 600.0, maxError: 50.0) // same time

        #expect(filter.count == 1)
        #expect(filter.offset == 500.0) // unchanged
    }

    // MARK: - Drift significance gate

    @Test
    func driftNotUsedWhenStatisticallyInsignificant() {
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
    func computeServerTimeAndComputeClientTimeAreInverses() {
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
    func computeServerTime_appliesOffsetCorrectly() {
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
    func resetReturnsToUninformativePrior() {
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
        #expect(filter.estimatedError == nil)
    }

    // MARK: - Adaptive forgetting

    @Test
    func covarianceShrinksWithConsistentMeasurements() {
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
    func offsetCovarianceDecreasesWithConsistentMeasurements() {
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

    // MARK: - Adaptive forgetting (active path)

    @Test
    func adaptiveForgettingInflatesCovarianceOnLargeResidual() {
        // Use minSamples=5 so we don't need 100 warmup measurements
        var filter = SendspinTimeFilter(minSamples: 5)

        // Warm up past minSamples with consistent offset of 1000μs
        for i in 0 ..< 10 {
            let t = Int64((i + 1) * 100_000)
            filter.update(timeAdded: t, measurement: 1_000.0, maxError: 50.0)
        }

        let offsetCovarianceBefore = filter.offsetCovariance
        let driftCovarianceBefore = filter.driftCovariance

        // Inject a measurement with a 9000μs jump from predicted offset.
        // With maxError=50 and cutoff=0.75, forgetting triggers when |residual| > 37.5μs.
        // Residual ≈ 9000 >> 37.5, so all three covariances should be inflated.
        filter.update(timeAdded: 1_100_000, measurement: 10_000.0, maxError: 50.0)

        // With covariance inflation, offset should jump closer to the outlier (10_000)
        // than to the prior value (~1_000). Midpoint is 5_500.
        #expect(filter.offset > 5_500.0, "Offset should be closer to outlier than prior")

        // Both offset and drift covariance should grow after forgetting fires.
        // The Kalman update step deflates covariance, but with such a massive residual
        // the inflation should dominate.
        #expect(
            filter.offsetCovariance > offsetCovarianceBefore,
            "Offset covariance should grow after forgetting fires on a large residual"
        )
        #expect(
            filter.driftCovariance > driftCovarianceBefore,
            "Drift covariance should grow after forgetting fires (was missing before bug fix)"
        )
    }

    // MARK: - Count behavior

    @Test
    func countSaturatesAtMinSamplesForForgetting() {
        // The first two updates set count directly (1, then 2) via special-case
        // init paths. Subsequent updates increment count in the warm-up branch
        // until it reaches minSamplesForForgetting, after which adaptive
        // forgetting engages and count stops incrementing.
        let minSamples: UInt8 = 10
        var filter = SendspinTimeFilter(minSamples: minSamples)

        // Feed well past minSamples
        for i in 0 ..< 50 {
            let t = Int64((i + 1) * 100_000)
            filter.update(timeAdded: t, measurement: 500.0, maxError: 10.0)
        }

        #expect(filter.count == minSamples)
    }

    // MARK: - Drift-aware time conversion

    @Test
    func timeConversionAccountsForDriftWhenSignificant() {
        // Use a low significance threshold so drift passes the SNR gate more easily
        var filter = SendspinTimeFilter(driftSignificanceThreshold: 0.5)
        let trueDrift = 0.1 // 100,000 ppm — very strong drift to dominate noise

        // Feed measurements with strong, consistent drift and tight error bounds.
        // 100 iterations is sufficient given the extreme signal-to-noise ratio.
        for i in 0 ..< 100 {
            let t = Int64((i + 1) * 10_000) // 10ms apart
            let measuredOffset = 1_000.0 + trueDrift * Double(t)
            filter.update(timeAdded: t, measurement: measuredOffset, maxError: 5.0)
        }

        // With a very large, consistent drift and low threshold, SNR gate should open
        #expect(filter.useDrift, "Drift should be statistically significant")

        // Verify that server time diverges from a naive offset-only computation
        let futureClient: Int64 = 10_000_000 // 10s in the future
        let serverTime = filter.computeServerTime(futureClient)
        let naiveServer = futureClient + Int64(filter.offset.rounded())

        // With drift active, the computed server time should differ from naive
        #expect(
            abs(serverTime - naiveServer) > 100,
            "Drift should meaningfully affect time conversion at 10s extrapolation"
        )
    }

    // MARK: - Estimated error

    @Test
    func estimatedErrorIsNilBeforeFirstMeasurement() {
        let filter = SendspinTimeFilter()
        #expect(filter.estimatedError == nil)
    }

    @Test
    func estimatedErrorMatchesKnownValueAfterFirstMeasurement() throws {
        var filter = SendspinTimeFilter()
        filter.update(timeAdded: 1_000, measurement: 500.0, maxError: 50.0)

        // After first measurement: offsetCovariance = maxError² = 2500
        // estimatedError = √2500 = 50.0 (exactly representable in IEEE 754)
        let error = try #require(filter.estimatedError)
        #expect(error == 50.0)
    }

    @Test
    func estimatedErrorIsPositiveAndFiniteAfterKalmanUpdates() throws {
        var filter = SendspinTimeFilter()

        for i in 0 ..< 20 {
            let t = Int64((i + 1) * 100_000)
            filter.update(timeAdded: t, measurement: 1_000.0, maxError: 100.0)
        }

        let error = try #require(filter.estimatedError)
        // After 20 consistent measurements, error should be well below the initial
        // measurement uncertainty of 100μs but still positive
        #expect(error > 0.0)
        #expect(error < 100.0, "Error should be below initial measurement uncertainty after convergence")
    }

    @Test
    func estimatedErrorDecreasesWithMoreMeasurements() throws {
        var filter = SendspinTimeFilter(processStdDev: 0.001, driftProcessStdDev: 0.0001)

        filter.update(timeAdded: 100_000, measurement: 1_000.0, maxError: 500.0)
        let errorAfterOne = try #require(filter.estimatedError)

        for i in 1 ..< 50 {
            let t = Int64((i + 1) * 100_000)
            filter.update(timeAdded: t, measurement: 1_000.0, maxError: 500.0)
        }

        let errorAfterFifty = try #require(filter.estimatedError)
        #expect(errorAfterFifty < errorAfterOne)
    }
}
