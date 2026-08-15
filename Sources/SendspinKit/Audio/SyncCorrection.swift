import Foundation

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

/// Windowed comparison between wire timestamp spacing and decoded PCM duration.
struct ChunkTimingDiagnostics {
    struct Snapshot {
        let chunkCount: Int
        let pairedCount: Int
        let timestampDeltaMinUs: Int64?
        let timestampDeltaMaxUs: Int64?
        let decodedDurationMinUs: Int64?
        let decodedDurationMaxUs: Int64?
        let meanMismatchUs: Double?
        let meanAbsoluteMismatchUs: Double?
        let maximumAbsoluteMismatchUs: Int64?

        var summary: String {
            guard chunkCount > 0 else { return "none" }
            let timestampRange = range(timestampDeltaMinUs, timestampDeltaMaxUs)
            let decodedRange = range(decodedDurationMinUs, decodedDurationMaxUs)
            guard pairedCount > 0 else {
                return "chunks=\(chunkCount) pairs=0 decoded=\(decodedRange)"
            }
            let mean = String(format: "%.1f", meanMismatchUs ?? 0)
            let absoluteMean = String(format: "%.1f", meanAbsoluteMismatchUs ?? 0)
            let maximum = maximumAbsoluteMismatchUs ?? 0
            return "chunks=\(chunkCount) pairs=\(pairedCount)"
                + " ts=\(timestampRange) decoded=\(decodedRange)"
                + " mismatch=mean:\(mean)us absMean:\(absoluteMean)us max:\(maximum)us"
        }

        private func range(_ minimum: Int64?, _ maximum: Int64?) -> String {
            guard let minimum, let maximum else { return "n/a" }
            return "\(minimum)...\(maximum)us"
        }
    }

    private var previousTimestampUs: Int64?
    private var previousDecodedFrameCount: Int64?
    private var previousSampleRate: Int?
    private(set) var chunkCount = 0
    private(set) var pairedCount = 0
    private(set) var timestampDeltaMinUs: Int64?
    private(set) var timestampDeltaMaxUs: Int64?
    private(set) var decodedDurationMinUs: Int64?
    private(set) var decodedDurationMaxUs: Int64?
    private var totalMismatchUs: Int64 = 0
    private var totalAbsoluteMismatchUs: Int64 = 0
    private(set) var maximumAbsoluteMismatchUs: Int64?

    mutating func record(timestampUs: Int64, decodedFrameCount: Int64, sampleRate: Int) {
        guard decodedFrameCount > 0, sampleRate > 0 else { return }

        chunkCount += 1
        let decodedDurationUs = Int64((Double(decodedFrameCount) * 1_000_000.0 / Double(sampleRate)).rounded())
        decodedDurationMinUs = minOptional(decodedDurationMinUs, decodedDurationUs)
        decodedDurationMaxUs = maxOptional(decodedDurationMaxUs, decodedDurationUs)

        if let previousTimestampUs, let previousDecodedFrameCount, previousSampleRate == sampleRate {
            let timestampDelta = timestampUs - previousTimestampUs
            if timestampDelta > 0 {
                let previousDecodedDurationUs = Int64(
                    (Double(previousDecodedFrameCount) * 1_000_000.0 / Double(sampleRate)).rounded()
                )
                let mismatch = previousDecodedDurationUs - timestampDelta
                pairedCount += 1
                timestampDeltaMinUs = minOptional(timestampDeltaMinUs, timestampDelta)
                timestampDeltaMaxUs = maxOptional(timestampDeltaMaxUs, timestampDelta)
                totalMismatchUs += mismatch
                totalAbsoluteMismatchUs += abs(mismatch)
                maximumAbsoluteMismatchUs = maxOptional(maximumAbsoluteMismatchUs, abs(mismatch))
            }
        }

        previousTimestampUs = timestampUs
        previousDecodedFrameCount = decodedFrameCount
        previousSampleRate = sampleRate
    }

    mutating func takeSnapshot() -> Snapshot {
        let snapshot = Snapshot(
            chunkCount: chunkCount,
            pairedCount: pairedCount,
            timestampDeltaMinUs: timestampDeltaMinUs,
            timestampDeltaMaxUs: timestampDeltaMaxUs,
            decodedDurationMinUs: decodedDurationMinUs,
            decodedDurationMaxUs: decodedDurationMaxUs,
            meanMismatchUs: pairedCount > 0 ? Double(totalMismatchUs) / Double(pairedCount) : nil,
            meanAbsoluteMismatchUs: pairedCount > 0 ? Double(totalAbsoluteMismatchUs) / Double(pairedCount) : nil,
            maximumAbsoluteMismatchUs: maximumAbsoluteMismatchUs
        )
        self = Self()
        return snapshot
    }

    private func minOptional(_ current: Int64?, _ candidate: Int64) -> Int64 {
        min(current ?? candidate, candidate)
    }

    private func maxOptional(_ current: Int64?, _ candidate: Int64) -> Int64 {
        max(current ?? candidate, candidate)
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
    /// Default sync-correction policy for player output.
    ///
    /// Soft correction starts at the recommended accuracy target and stops once
    /// error falls into the dead band. Reanchor remains a rare recovery path for
    /// large discontinuities, not the normal steady-state correction mechanism.
    static let defaultDeadbandUs: Int64 = 100
    static let defaultEngageUs: Int64 = 500
    static let defaultReanchorThresholdUs: Int64 = 500_000
    static let defaultTargetSeconds: Double = 2.0
    static let defaultMaxSpeedCorrection: Double = 0.005

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
