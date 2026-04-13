// ABOUTME: Tests for CorrectionPlanner and CorrectionSchedule
// ABOUTME: Translated from sendspin-rs/tests/sync_correction.rs and src/audio/sync_correction.rs

@testable import SendspinKit
import Testing

struct SyncCorrectionTests {
    // Reference the planner's default constants so tests break if they change.
    private static let deadbandUs = CorrectionPlanner.defaultDeadbandUs
    private static let engageUs = CorrectionPlanner.defaultEngageUs
    private static let reanchorUs = CorrectionPlanner.defaultReanchorThresholdUs

    // MARK: - Integration tests (from tests/sync_correction.rs)

    @Test
    func `deadband - small error produces no correction`() {
        let planner = CorrectionPlanner()
        let schedule = planner.plan(errorMicroseconds: Self.deadbandUs - 500, sampleRate: 48_000, currentlyCorrecting: false)
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
        let schedule = planner.plan(errorMicroseconds: Self.reanchorUs + 100_000, sampleRate: 48_000, currentlyCorrecting: false)
        #expect(schedule.reanchor)
    }

    // MARK: - Unit tests (from src/audio/sync_correction.rs inline tests)

    @Test
    func `no correction within engage threshold`() {
        let planner = CorrectionPlanner()
        // Below engage threshold — should not start correcting
        let schedule = planner.plan(errorMicroseconds: Self.engageUs - 500, sampleRate: 48_000, currentlyCorrecting: false)
        #expect(!schedule.isCorrecting, "should not engage below engage threshold")
    }

    @Test
    func `correction engages above threshold`() {
        let planner = CorrectionPlanner()
        let schedule = planner.plan(errorMicroseconds: Self.engageUs + 500, sampleRate: 48_000, currentlyCorrecting: false)
        #expect(schedule.isCorrecting, "should engage above engage threshold")
        #expect(schedule.dropEveryNFrames > 0, "positive error = drop")
    }

    @Test
    func `hysteresis keeps correcting above deadband`() {
        let planner = CorrectionPlanner()
        // Between deadband and engage — should keep correcting if already active
        let midpoint = Self.deadbandUs + (Self.engageUs - Self.deadbandUs) / 2
        let schedule = planner.plan(errorMicroseconds: midpoint, sampleRate: 48_000, currentlyCorrecting: true)
        #expect(schedule.isCorrecting, "should keep correcting above deadband")
    }

    @Test
    func `hysteresis stops below deadband`() {
        let planner = CorrectionPlanner()
        let schedule = planner.plan(errorMicroseconds: Self.deadbandUs - 500, sampleRate: 48_000, currentlyCorrecting: true)
        #expect(!schedule.isCorrecting, "should stop below deadband")
    }

    @Test
    func `negative error inserts frames`() {
        let planner = CorrectionPlanner()
        let schedule = planner.plan(errorMicroseconds: -(Self.engageUs + 2_000), sampleRate: 48_000, currentlyCorrecting: false)
        #expect(schedule.insertEveryNFrames > 0, "negative error = insert")
        #expect(schedule.dropEveryNFrames == 0)
    }

    @Test
    func `reanchor at exact threshold`() {
        let planner = CorrectionPlanner()
        let schedule = planner.plan(errorMicroseconds: Self.reanchorUs, sampleRate: 48_000, currentlyCorrecting: false)
        #expect(schedule.reanchor)
    }

    @Test
    func `exact engage threshold does not engage`() {
        let planner = CorrectionPlanner()
        let schedule = planner.plan(errorMicroseconds: Self.engageUs, sampleRate: 48_000, currentlyCorrecting: false)
        #expect(!schedule.isCorrecting, "exactly at engage threshold should not engage (<=)")
    }

    @Test
    func `exact deadband threshold disengages`() {
        let planner = CorrectionPlanner()
        let schedule = planner.plan(errorMicroseconds: Self.deadbandUs, sampleRate: 48_000, currentlyCorrecting: true)
        #expect(!schedule.isCorrecting, "exactly at deadband threshold should disengage (<=)")
    }

    @Test
    func `negative hysteresis keeps inserting above deadband`() {
        let planner = CorrectionPlanner()
        let midpoint = Self.deadbandUs + (Self.engageUs - Self.deadbandUs) / 2
        let schedule = planner.plan(errorMicroseconds: -midpoint, sampleRate: 48_000, currentlyCorrecting: true)
        #expect(schedule.isCorrecting, "should keep correcting negative error above deadband")
        #expect(schedule.insertEveryNFrames > 0, "negative error = insert")
        #expect(schedule.dropEveryNFrames == 0)
    }
}
