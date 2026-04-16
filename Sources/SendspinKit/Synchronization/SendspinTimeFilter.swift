// ABOUTME: 2D Kalman filter for clock synchronization — tracks offset and drift
// ABOUTME: Port of the C++ reference at github.com/Sendspin-Protocol/time-filter

import Foundation

/// Two-dimensional Kalman filter tracking clock offset and drift rate.
///
/// This is a faithful port of the C++ reference implementation with:
/// - Full 2x2 covariance matrix propagation
/// - Per-sample measurement noise derived from RTT
/// - Adaptive forgetting factor for changing network conditions
/// - Drift significance SNR gate (only applies drift when statistically meaningful)
/// - RTT floor of 1μs to prevent zero-variance NaN on localhost (from Rust port)
///
/// Defaults match the reference project's README recommendations
/// (`time-filter/README.md`, "Recommended Values") — notably
/// `driftProcessStdDev = 0.0`. A nonzero drift process noise with typical
/// sync intervals (hundreds of ms) inflates `driftCovariance` fast enough
/// that the prediction step's `driftCov · dt²` term dominates `R`,
/// pinning `offsetCovariance` at `measurementVariance` every step — i.e.
/// the filter never learns from more than one sample.
///
/// Units: all timestamps in microseconds (Int64), offset/drift in microseconds (Double).
struct SendspinTimeFilter {
    // MARK: - State

    /// Client timestamp (μs) of the last accepted measurement
    private(set) var lastUpdate: Int64 = 0

    /// Current offset estimate (μs): server_time ≈ client_time + offset
    private(set) var offset: Double = 0.0

    /// Current drift estimate (μs/μs, dimensionless): offset changes by drift per μs
    private(set) var drift: Double = 0.0

    /// Covariance matrix [offset, drift]:
    ///   P = [[offsetCovariance, offsetDriftCovariance],
    ///        [offsetDriftCovariance, driftCovariance]]
    private(set) var offsetCovariance: Double = .infinity
    private(set) var offsetDriftCovariance: Double = 0.0
    private(set) var driftCovariance: Double = 0.0

    /// Whether the drift estimate is statistically significant (SNR gate)
    private(set) var useDrift: Bool = false

    /// Number of measurements processed (saturates at `minSamplesForForgetting`).
    /// Acts as a warm-up counter: once it reaches `minSamplesForForgetting`,
    /// adaptive forgetting engages and the count stops incrementing.
    private(set) var count: UInt8 = 0

    // MARK: - Configuration (immutable after init)

    /// Process noise variance for offset (per μs of elapsed time)
    private let processVariance: Double

    /// Process noise variance for drift (per μs of elapsed time)
    private let driftProcessVariance: Double

    /// Adaptive forgetting: covariance inflation factor (squared)
    private let forgetVarianceFactor: Double

    /// Adaptive forgetting: residual cutoff as fraction of max_error
    private let adaptiveForgettingCutoff: Double

    /// Minimum samples before adaptive forgetting engages
    private let minSamplesForForgetting: UInt8

    /// Drift SNR threshold (squared): drift² must exceed this × driftCovariance
    private let driftSignificanceThresholdSquared: Double

    // MARK: - Init

    /// Create a new time filter.
    ///
    /// Defaults match the reference project's `README.md` "Recommended Values"
    /// section. In particular, `driftProcessStdDev` defaults to `0.0` — a
    /// nonzero value causes `driftCovariance` to grow by `dt · q_drift` each
    /// step, and the `driftCov · dt²` term in the offset prediction then
    /// pins `offsetCovariance` at `measurementVariance` every cycle (the
    /// filter stops learning from multiple samples).
    ///
    /// - Parameters:
    ///   - processStdDev: Standard deviation of offset process noise. Default 0.01.
    ///   - driftProcessStdDev: Standard deviation of drift process noise.
    ///     Default 0.0 — treat drift as effectively constant between samples
    ///     (valid over minutes for any real oscillator).
    ///   - forgetFactor: Adaptive forgetting inflation factor (>1). Applied when
    ///     residuals exceed the cutoff after min_samples. Default 1.001.
    ///   - adaptiveCutoff: Fraction of max_error that triggers forgetting. Default 0.75.
    ///   - minSamples: Minimum measurements before forgetting engages. Default 100.
    ///   - driftSignificanceThreshold: SNR threshold for applying drift. Default 2.0.
    init(
        processStdDev: Double = 0.01,
        driftProcessStdDev: Double = 0.0,
        forgetFactor: Double = 1.001,
        adaptiveCutoff: Double = 0.75,
        minSamples: UInt8 = 100,
        driftSignificanceThreshold: Double = 2.0
    ) {
        processVariance = processStdDev * processStdDev
        driftProcessVariance = driftProcessStdDev * driftProcessStdDev
        forgetVarianceFactor = forgetFactor * forgetFactor
        adaptiveForgettingCutoff = adaptiveCutoff
        minSamplesForForgetting = minSamples
        driftSignificanceThresholdSquared = driftSignificanceThreshold * driftSignificanceThreshold
    }

    // MARK: - Update

    /// Feed a new measurement into the filter.
    ///
    /// - Parameters:
    ///   - timeAdded: Client timestamp (μs) when this measurement was taken.
    ///     Must be monotonically increasing.
    ///   - measurement: Measured clock offset (μs): server_time - client_time.
    ///   - maxError: Maximum measurement error (μs), typically RTT/2.
    ///     Floored to 1μs internally to prevent zero-variance on localhost.
    mutating func update(timeAdded: Int64, measurement: Double, maxError: Double) {
        // Guard: timestamps must be strictly monotonic
        guard timeAdded > lastUpdate || count == 0 else { return }

        // Floor max_error to 1μs to prevent zero measurement variance (Rust port fix)
        let clampedMaxError = max(maxError, 1.0)
        let measurementVariance = clampedMaxError * clampedMaxError

        let dt = Double(timeAdded - lastUpdate)

        // --- First measurement: initialize offset, no drift yet ---
        if count == 0 {
            offset = measurement
            offsetCovariance = measurementVariance
            drift = 0.0
            driftCovariance = 0.0
            offsetDriftCovariance = 0.0
            useDrift = false
            lastUpdate = timeAdded
            count = 1
            return
        }

        let dtSquared = dt * dt

        // --- Second measurement: initialize drift from finite difference ---
        if count == 1 {
            drift = (measurement - offset) / dt
            driftCovariance = (offsetCovariance + measurementVariance) / dtSquared
            offset = measurement
            offsetCovariance = measurementVariance
            offsetDriftCovariance = 0.0
            lastUpdate = timeAdded
            count = 2
            return
        }

        // --- Prediction step ---
        let predictedOffset = offset + drift * dt

        var newDriftCovariance = driftCovariance + dt * driftProcessVariance
        var newOffsetDriftCovariance = offsetDriftCovariance + driftCovariance * dt
        var newOffsetCovariance = offsetCovariance
            + 2.0 * offsetDriftCovariance * dt
            + driftCovariance * dtSquared
            + dt * processVariance

        // --- Adaptive forgetting ---
        let residual = measurement - predictedOffset

        if count < minSamplesForForgetting {
            count += 1
        } else {
            let maxResidualCutoff = clampedMaxError * adaptiveForgettingCutoff
            if abs(residual) > maxResidualCutoff {
                // Inflate all three predicted covariances to allow faster adaptation
                newDriftCovariance *= forgetVarianceFactor
                newOffsetDriftCovariance *= forgetVarianceFactor
                newOffsetCovariance *= forgetVarianceFactor
            }
        }

        // --- Update step (standard Kalman) ---
        let innovation = newOffsetCovariance + measurementVariance // S = H·P·Hᵀ + R
        let uncertainty = 1.0 / innovation

        let offsetGain = newOffsetCovariance * uncertainty // K[0]
        let driftGain = newOffsetDriftCovariance * uncertainty // K[1]

        offset = predictedOffset + offsetGain * residual
        drift += driftGain * residual

        // Update covariance: P = (I - K·H)·P
        driftCovariance = newDriftCovariance - driftGain * newOffsetDriftCovariance
        offsetDriftCovariance = newOffsetDriftCovariance - driftGain * newOffsetCovariance
        offsetCovariance = newOffsetCovariance - offsetGain * newOffsetCovariance

        lastUpdate = timeAdded

        // --- Drift significance gate (SNR check) ---
        // Only apply drift in time conversions when it's statistically meaningful.
        // drift² > threshold² × driftCovariance means drift is significantly nonzero.
        useDrift = (drift * drift) > driftSignificanceThresholdSquared * driftCovariance
    }

    // MARK: - Time conversion

    /// Convert a client timestamp to the corresponding server timestamp.
    ///
    /// - Parameter clientTime: Client-domain timestamp (μs)
    /// - Returns: Estimated server-domain timestamp (μs)
    func computeServerTime(_ clientTime: Int64) -> Int64 {
        let effectiveDrift = useDrift ? drift : 0.0
        let currentOffset = offset + effectiveDrift * Double(clientTime - lastUpdate)
        return clientTime + Int64(currentOffset.rounded())
    }

    /// Convert a server timestamp to the corresponding client timestamp.
    ///
    /// - Parameter serverTime: Server-domain timestamp (μs)
    /// - Returns: Estimated client-domain timestamp (μs)
    func computeClientTime(_ serverTime: Int64) -> Int64 {
        let effectiveDrift = useDrift ? drift : 0.0
        let numerator = Double(serverTime) - offset + effectiveDrift * Double(lastUpdate)
        let denominator = 1.0 + effectiveDrift
        return Int64((numerator / denominator).rounded())
    }

    // MARK: - Diagnostics

    /// Whether the filter has received at least one measurement
    var isInitialized: Bool {
        count > 0
    }

    /// Estimated standard deviation of the offset in microseconds.
    /// Equivalent to C++ `get_error()`. Returns `nil` before the first measurement.
    var estimatedError: Double? {
        guard isInitialized else { return nil }
        assert(offsetCovariance >= 0, "Covariance matrix lost positive-semidefiniteness")
        return sqrt(max(offsetCovariance, 0.0))
    }

    /// Reset the filter to its initial state
    mutating func reset() {
        count = 0
        offset = 0.0
        drift = 0.0
        offsetCovariance = .infinity
        offsetDriftCovariance = 0.0
        driftCovariance = 0.0
        lastUpdate = 0
        useDrift = false
    }
}
