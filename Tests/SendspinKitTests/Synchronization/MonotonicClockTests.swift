// ABOUTME: Tests for MonotonicClock — basic sanity checks for the process-wide clock source
// ABOUTME: Verifies monotonicity, positivity, and epoch anchor relationship

import Foundation
@testable import SendspinKit
import Testing

struct MonotonicClockTests {
    // 2020-01-01T00:00:00Z in seconds since Unix epoch
    private static let epoch2020Seconds: Int64 = 1_577_836_800
    // 2100-01-01T00:00:00Z in seconds since Unix epoch
    private static let epoch2100Seconds: Int64 = 4_102_444_800

    /// Maximum expected elapsed time between two sequential clock reads on the
    /// same thread. 100μs is generous — Apple Silicon does clock_gettime in ~40-80ns.
    private static let sequentialCallToleranceMicroseconds: Int64 = 100

    @Test
    func `nowMicroseconds returns positive values`() {
        let now = MonotonicClock.nowMicroseconds()
        #expect(now > 0)
    }

    @Test
    func `nowMicroseconds is monotonically increasing`() {
        let first = MonotonicClock.nowMicroseconds()
        let second = MonotonicClock.nowMicroseconds()
        #expect(second >= first)
    }

    @Test
    func `nowMicroseconds advances over a real delay`() async throws {
        let before = MonotonicClock.nowMicroseconds()
        try await Task.sleep(for: .milliseconds(10))
        let after = MonotonicClock.nowMicroseconds()

        // At least 9ms should have elapsed (allowing 1ms scheduling slack)
        let elapsedMicroseconds = after - before
        #expect(elapsedMicroseconds >= 9_000, "Expected ≥9ms elapsed, got \(elapsedMicroseconds)μs")
    }

    @Test
    func `absoluteMicroseconds is greater than nowMicroseconds`() {
        // The epoch anchor (Unix epoch offset) is always a large positive number
        // on real hardware, so absolute time > process-relative time.
        let relative = MonotonicClock.nowMicroseconds()
        let absolute = MonotonicClock.absoluteMicroseconds()
        #expect(absolute > relative)
    }

    @Test
    func `absoluteMicroseconds equals nowMicroseconds plus epoch anchor`() {
        // Capture as close together as possible
        let now = MonotonicClock.nowMicroseconds()
        let absolute = MonotonicClock.absoluteMicroseconds()
        let anchor = MonotonicClock.epochAnchorMicroseconds

        let expected = now + anchor
        #expect(
            abs(absolute - expected) < Self.sequentialCallToleranceMicroseconds,
            "absoluteMicroseconds drifted \(abs(absolute - expected))μs from expected"
        )
    }

    @Test
    func `absoluteMicroseconds is a plausible Unix timestamp`() {
        let absolute = MonotonicClock.absoluteMicroseconds()

        let lowerBound = Self.epoch2020Seconds * 1_000_000
        let upperBound = Self.epoch2100Seconds * 1_000_000

        #expect(absolute > lowerBound, "absoluteMicroseconds should be after 2020")
        #expect(absolute < upperBound, "absoluteMicroseconds should be before 2100")
    }
}
