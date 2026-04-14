// ABOUTME: Sync correction planner for drop/insert cadence
// ABOUTME: Computes correction schedule from sync error and sample rate

/// Correction schedule for drop/insert cadence
struct CorrectionSchedule: Equatable {
    /// Insert one frame every N frames (0 = disabled)
    let insertEveryNFrames: UInt32
    /// Drop one frame every N frames (0 = disabled)
    let dropEveryNFrames: UInt32
    /// True when re-anchoring is required
    let reanchor: Bool

    init(insertEveryNFrames: UInt32 = 0, dropEveryNFrames: UInt32 = 0, reanchor: Bool = false) {
        self.insertEveryNFrames = insertEveryNFrames
        self.dropEveryNFrames = dropEveryNFrames
        self.reanchor = reanchor
    }

    /// True when any correction (insert, drop, or reanchor) is active
    var isCorrecting: Bool {
        insertEveryNFrames > 0 || dropEveryNFrames > 0 || reanchor
    }
}

/// Planner that converts sync error into a correction schedule.
///
/// Uses hysteresis to prevent oscillation at the deadband boundary:
/// correction engages at `engageMicroseconds` and disengages at `deadbandMicroseconds`.
///
/// Purely functional — all stored properties are immutable. No accumulated state
/// between calls; each `plan()` invocation depends only on its arguments.
struct CorrectionPlanner {
    /// Default tuning constants — exposed for test assertions against boundary values.
    static let defaultDeadbandUs: Int64 = 1_500
    static let defaultEngageUs: Int64 = 3_000
    static let defaultReanchorThresholdUs: Int64 = 500_000
    static let defaultTargetSeconds: Double = 2.0
    static let defaultMaxSpeedCorrection: Double = 0.04

    let deadbandMicroseconds: Int64
    let engageMicroseconds: Int64
    let reanchorThresholdMicroseconds: Int64
    let targetSeconds: Double
    let maxSpeedCorrection: Double

    init(
        deadbandMicroseconds: Int64 = defaultDeadbandUs,
        engageMicroseconds: Int64 = defaultEngageUs,
        reanchorThresholdMicroseconds: Int64 = defaultReanchorThresholdUs,
        targetSeconds: Double = defaultTargetSeconds,
        maxSpeedCorrection: Double = defaultMaxSpeedCorrection
    ) {
        precondition(
            deadbandMicroseconds < engageMicroseconds,
            "deadband must be less than engage for hysteresis"
        )
        precondition(
            engageMicroseconds < reanchorThresholdMicroseconds,
            "engage must be less than reanchor threshold"
        )
        self.deadbandMicroseconds = deadbandMicroseconds
        self.engageMicroseconds = engageMicroseconds
        self.reanchorThresholdMicroseconds = reanchorThresholdMicroseconds
        self.targetSeconds = targetSeconds
        self.maxSpeedCorrection = maxSpeedCorrection
    }

    /// Plan a correction schedule from sync error and sample rate.
    ///
    /// - Parameters:
    ///   - errorMicroseconds: Sync error in microseconds (positive = cursor behind server,
    ///     drop frames to catch up; negative = cursor ahead, insert frames to slow down)
    ///   - sampleRate: Audio sample rate in Hz (must be > 0)
    ///   - currentlyCorrecting: Controls hysteresis; when true, the lower deadband threshold is used
    func plan(errorMicroseconds: Int64, sampleRate: UInt32, currentlyCorrecting: Bool) -> CorrectionSchedule {
        precondition(sampleRate > 0, "sample rate must be positive")

        // abs(Int64.min) traps in Swift; saturate to max, which triggers reanchor.
        let absError: Int64 = if errorMicroseconds == Int64.min {
            Int64.max
        } else {
            abs(errorMicroseconds)
        }

        // Hysteresis: use lower threshold to keep correcting, higher to start
        let threshold = currentlyCorrecting ? deadbandMicroseconds : engageMicroseconds

        if absError <= threshold {
            return CorrectionSchedule()
        }

        if absError >= reanchorThresholdMicroseconds {
            return CorrectionSchedule(reanchor: true)
        }

        let sampleRateF = Double(sampleRate)
        let framesError = (Double(errorMicroseconds) * sampleRateF) / 1_000_000.0
        let desiredCorrectionsPerSec = abs(framesError) / targetSeconds
        let maxCorrectionsPerSec = sampleRateF * maxSpeedCorrection
        let correctionsPerSec = min(desiredCorrectionsPerSec, maxCorrectionsPerSec)
        let intervalFrames = UInt32((sampleRateF / correctionsPerSec).rounded(.toNearestOrAwayFromZero))

        if errorMicroseconds > 0 {
            return CorrectionSchedule(dropEveryNFrames: max(intervalFrames, 1))
        } else {
            return CorrectionSchedule(insertEveryNFrames: max(intervalFrames, 1))
        }
    }
}
