// ABOUTME: Tests for CorrectionPlanner and CorrectionSchedule
// ABOUTME: Translated from sendspin-rs/tests/sync_correction.rs and src/audio/sync_correction.rs

@testable import SendspinKit
import Testing

struct SyncCorrectionTests {
    // MARK: - Integration tests (from tests/sync_correction.rs)

    @Test
    func `deadband - small error produces no correction`() {
        let planner = CorrectionPlanner()
        let schedule = planner.plan(errorMicroseconds: 1_000, sampleRate: 48_000, currentlyCorrecting: false)
        #expect(schedule == CorrectionSchedule())
    }

    @Test
    func `positive error produces drop schedule`() {
        let planner = CorrectionPlanner()
        let schedule = planner.plan(errorMicroseconds: 200_000, sampleRate: 48_000, currentlyCorrecting: false)
        #expect(schedule.dropEveryNFrames > 0)
        #expect(schedule.insertEveryNFrames == 0)
        #expect(!schedule.reanchor)
    }

    @Test
    func `negative error produces insert schedule`() {
        let planner = CorrectionPlanner()
        let schedule = planner.plan(errorMicroseconds: -200_000, sampleRate: 48_000, currentlyCorrecting: false)
        #expect(schedule.insertEveryNFrames > 0)
        #expect(schedule.dropEveryNFrames == 0)
        #expect(!schedule.reanchor)
    }

    @Test
    func `large error triggers reanchor`() {
        let planner = CorrectionPlanner()
        let schedule = planner.plan(errorMicroseconds: 600_000, sampleRate: 48_000, currentlyCorrecting: false)
        #expect(schedule.reanchor)
    }

    // MARK: - Unit tests (from src/audio/sync_correction.rs inline tests)

    @Test
    func `no correction within engage threshold`() {
        let planner = CorrectionPlanner()
        let schedule = planner.plan(errorMicroseconds: 2_500, sampleRate: 48_000, currentlyCorrecting: false)
        #expect(!schedule.isCorrecting, "should not engage below 3ms")
    }

    @Test
    func `correction engages above threshold`() {
        let planner = CorrectionPlanner()
        let schedule = planner.plan(errorMicroseconds: 3_500, sampleRate: 48_000, currentlyCorrecting: false)
        #expect(schedule.isCorrecting, "should engage above 3ms")
        #expect(schedule.dropEveryNFrames > 0, "positive error = drop")
    }

    @Test
    func `hysteresis keeps correcting above deadband`() {
        let planner = CorrectionPlanner()
        // 2ms error: below engage (3ms) but above deadband (1.5ms)
        // Should keep correcting if already active
        let schedule = planner.plan(errorMicroseconds: 2_000, sampleRate: 48_000, currentlyCorrecting: true)
        #expect(schedule.isCorrecting, "should keep correcting above 1.5ms deadband")
    }

    @Test
    func `hysteresis stops below deadband`() {
        let planner = CorrectionPlanner()
        let schedule = planner.plan(errorMicroseconds: 1_000, sampleRate: 48_000, currentlyCorrecting: true)
        #expect(!schedule.isCorrecting, "should stop below 1.5ms deadband")
    }

    @Test
    func `negative error inserts frames`() {
        let planner = CorrectionPlanner()
        let schedule = planner.plan(errorMicroseconds: -5_000, sampleRate: 48_000, currentlyCorrecting: false)
        #expect(schedule.insertEveryNFrames > 0, "negative error = insert")
        #expect(schedule.dropEveryNFrames == 0)
    }

    @Test
    func `reanchor at large error`() {
        let planner = CorrectionPlanner()
        let schedule = planner.plan(errorMicroseconds: 500_000, sampleRate: 48_000, currentlyCorrecting: false)
        #expect(schedule.reanchor)
    }

    @Test
    func `exact engage threshold does not engage`() {
        let planner = CorrectionPlanner()
        let schedule = planner.plan(errorMicroseconds: 3_000, sampleRate: 48_000, currentlyCorrecting: false)
        #expect(!schedule.isCorrecting, "exactly at engage threshold should not engage (<=)")
    }

    @Test
    func `exact deadband threshold disengages`() {
        let planner = CorrectionPlanner()
        let schedule = planner.plan(errorMicroseconds: 1_500, sampleRate: 48_000, currentlyCorrecting: true)
        #expect(!schedule.isCorrecting, "exactly at deadband threshold should disengage (<=)")
    }

    @Test
    func `negative hysteresis keeps inserting above deadband`() {
        let planner = CorrectionPlanner()
        let schedule = planner.plan(errorMicroseconds: -2_000, sampleRate: 48_000, currentlyCorrecting: true)
        #expect(schedule.isCorrecting, "should keep correcting negative error above deadband")
        #expect(schedule.insertEveryNFrames > 0, "negative error = insert")
        #expect(schedule.dropEveryNFrames == 0)
    }
}
