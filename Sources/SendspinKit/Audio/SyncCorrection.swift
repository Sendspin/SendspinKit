// ABOUTME: Sync correction planner for drop/insert cadence
// ABOUTME: Computes correction schedule from sync error and sample rate

import Foundation

/// Correction schedule for drop/insert cadence
public struct CorrectionSchedule: Equatable, Sendable {
    /// Insert one frame every N frames (0 = disabled)
    public var insertEveryNFrames: UInt32
    /// Drop one frame every N frames (0 = disabled)
    public var dropEveryNFrames: UInt32
    /// True when re-anchoring is required
    public var reanchor: Bool

    public init(insertEveryNFrames: UInt32 = 0, dropEveryNFrames: UInt32 = 0, reanchor: Bool = false) {
        self.insertEveryNFrames = insertEveryNFrames
        self.dropEveryNFrames = dropEveryNFrames
        self.reanchor = reanchor
    }

    /// True when any correction (insert, drop, or reanchor) is active
    public var isCorrecting: Bool {
        insertEveryNFrames > 0 || dropEveryNFrames > 0 || reanchor
    }
}

/// Planner that converts sync error into a correction schedule.
///
/// Uses hysteresis to prevent oscillation at the deadband boundary:
/// correction engages at `engageMicroseconds` and disengages at `deadbandMicroseconds`.
public struct CorrectionPlanner: Sendable {
    private let deadbandMicroseconds: Int64
    private let engageMicroseconds: Int64
    private let reanchorThresholdMicroseconds: Int64
    private let targetSeconds: Double
    private let maxSpeedCorrection: Double

    public init(
        deadbandMicroseconds: Int64 = 1_500,
        engageMicroseconds: Int64 = 3_000,
        reanchorThresholdMicroseconds: Int64 = 500_000,
        targetSeconds: Double = 2.0,
        maxSpeedCorrection: Double = 0.04
    ) {
        self.deadbandMicroseconds = deadbandMicroseconds
        self.engageMicroseconds = engageMicroseconds
        self.reanchorThresholdMicroseconds = reanchorThresholdMicroseconds
        self.targetSeconds = targetSeconds
        self.maxSpeedCorrection = maxSpeedCorrection
    }

    /// Plan a correction schedule from sync error and sample rate.
    ///
    /// - Parameters:
    ///   - errorMicroseconds: Sync error in microseconds (positive = ahead, negative = behind)
    ///   - sampleRate: Audio sample rate in Hz
    ///   - currentlyCorrecting: Controls hysteresis; when true, the lower deadband threshold is used
    public func plan(errorMicroseconds: Int64, sampleRate: UInt32, currentlyCorrecting: Bool) -> CorrectionSchedule {
        let absError: Int64
        if errorMicroseconds == Int64.min {
            absError = Int64.max
        } else {
            absError = abs(errorMicroseconds)
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
        let desiredCorrectionsPerSec = Swift.abs(framesError) / targetSeconds
        let maxCorrectionsPerSec = sampleRateF * maxSpeedCorrection
        let correctionsPerSec = Swift.min(desiredCorrectionsPerSec, maxCorrectionsPerSec)

        if correctionsPerSec <= 0.0 {
            return CorrectionSchedule()
        }

        let intervalFrames = UInt32((sampleRateF / correctionsPerSec).rounded())

        if errorMicroseconds > 0 {
            return CorrectionSchedule(dropEveryNFrames: Swift.max(intervalFrames, 1))
        } else {
            return CorrectionSchedule(insertEveryNFrames: Swift.max(intervalFrames, 1))
        }
    }
}
