// ABOUTME: Tests for CorrectionPlanner and CorrectionSchedule
// ABOUTME: Translated from sendspin-rs/tests/sync_correction.rs and src/audio/sync_correction.rs

import Testing
@testable import SendspinKit

@Suite("Sync Correction")
struct SyncCorrectionTests {

    // MARK: - Integration tests (from tests/sync_correction.rs)

    @Test("deadband - small error produces no correction")
    func correctionDeadband() {
        let planner = CorrectionPlanner()
        let schedule = planner.plan(errorMicroseconds: 1_000, sampleRate: 48_000, currentlyCorrecting: false)
        #expect(schedule == CorrectionSchedule())
    }

    @Test("positive error produces drop schedule")
    func correctionDrop() {
        let planner = CorrectionPlanner()
        let schedule = planner.plan(errorMicroseconds: 200_000, sampleRate: 48_000, currentlyCorrecting: false)
        #expect(schedule.dropEveryNFrames > 0)
        #expect(schedule.insertEveryNFrames == 0)
        #expect(!schedule.reanchor)
    }

    @Test("negative error produces insert schedule")
    func correctionInsert() {
        let planner = CorrectionPlanner()
        let schedule = planner.plan(errorMicroseconds: -200_000, sampleRate: 48_000, currentlyCorrecting: false)
        #expect(schedule.insertEveryNFrames > 0)
        #expect(schedule.dropEveryNFrames == 0)
        #expect(!schedule.reanchor)
    }

    @Test("large error triggers reanchor")
    func correctionReanchor() {
        let planner = CorrectionPlanner()
        let schedule = planner.plan(errorMicroseconds: 600_000, sampleRate: 48_000, currentlyCorrecting: false)
        #expect(schedule.reanchor)
    }

    // MARK: - Unit tests (from src/audio/sync_correction.rs inline tests)

    @Test("no correction within engage threshold")
    func noCorrectionWithinEngageThreshold() {
        let planner = CorrectionPlanner()
        let schedule = planner.plan(errorMicroseconds: 2_500, sampleRate: 48_000, currentlyCorrecting: false)
        #expect(!schedule.isCorrecting, "should not engage below 3ms")
    }

    @Test("correction engages above threshold")
    func correctionEngagesAboveThreshold() {
        let planner = CorrectionPlanner()
        let schedule = planner.plan(errorMicroseconds: 3_500, sampleRate: 48_000, currentlyCorrecting: false)
        #expect(schedule.isCorrecting, "should engage above 3ms")
        #expect(schedule.dropEveryNFrames > 0, "positive error = drop")
    }

    @Test("hysteresis keeps correcting above deadband")
    func hysteresisKeepsCorrecting() {
        let planner = CorrectionPlanner()
        // 2ms error: below engage (3ms) but above deadband (1.5ms)
        // Should keep correcting if already active
        let schedule = planner.plan(errorMicroseconds: 2_000, sampleRate: 48_000, currentlyCorrecting: true)
        #expect(schedule.isCorrecting, "should keep correcting above 1.5ms deadband")
    }

    @Test("hysteresis stops below deadband")
    func hysteresisStopsBelowDeadband() {
        let planner = CorrectionPlanner()
        let schedule = planner.plan(errorMicroseconds: 1_000, sampleRate: 48_000, currentlyCorrecting: true)
        #expect(!schedule.isCorrecting, "should stop below 1.5ms deadband")
    }

    @Test("negative error inserts frames")
    func negativeErrorInserts() {
        let planner = CorrectionPlanner()
        let schedule = planner.plan(errorMicroseconds: -5_000, sampleRate: 48_000, currentlyCorrecting: false)
        #expect(schedule.insertEveryNFrames > 0, "negative error = insert")
        #expect(schedule.dropEveryNFrames == 0)
    }

    @Test("reanchor at large error")
    func reanchorAtLargeError() {
        let planner = CorrectionPlanner()
        let schedule = planner.plan(errorMicroseconds: 500_000, sampleRate: 48_000, currentlyCorrecting: false)
        #expect(schedule.reanchor)
    }

    @Test("exact engage threshold does not engage")
    func exactEngageThresholdDoesNotEngage() {
        let planner = CorrectionPlanner()
        let schedule = planner.plan(errorMicroseconds: 3_000, sampleRate: 48_000, currentlyCorrecting: false)
        #expect(!schedule.isCorrecting, "exactly at engage threshold should not engage (<=)")
    }

    @Test("exact deadband threshold disengages")
    func exactDeadbandThresholdDisengages() {
        let planner = CorrectionPlanner()
        let schedule = planner.plan(errorMicroseconds: 1_500, sampleRate: 48_000, currentlyCorrecting: true)
        #expect(!schedule.isCorrecting, "exactly at deadband threshold should disengage (<=)")
    }

    @Test("negative hysteresis keeps inserting above deadband")
    func negativeHysteresisKeepsInsertingAboveDeadband() {
        let planner = CorrectionPlanner()
        let schedule = planner.plan(errorMicroseconds: -2_000, sampleRate: 48_000, currentlyCorrecting: true)
        #expect(schedule.isCorrecting, "should keep correcting negative error above deadband")
        #expect(schedule.insertEveryNFrames > 0, "negative error = insert")
        #expect(schedule.dropEveryNFrames == 0)
    }
}
