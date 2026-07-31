import Foundation
@testable import SendspinKit
import Testing

/// Server-supplied timestamps must not trap when arithmetic reaches an `Int64` boundary.
/// These tests exercise both the rejection path and the saturating conversion paths.
struct WireTimestampOverflowTests {
    // MARK: - processServerTime

    /// The RTT gate runs *after* the offset/RTT arithmetic, so overflow must be handled
    /// during the computation, not by the gate.
    @Test("server/time with Int64 extremes is rejected, not trapped")
    func extremeServerTimestampsAreRejected() async {
        let clock = ClockSynchronizer()

        await clock.processServerTime(
            clientTransmitted: 0,
            serverReceived: .min,
            serverTransmitted: .max,
            clientReceived: 0
        )

        #expect(await clock.lastSampleWasRejected, "an unrepresentable sample must be rejected")
        #expect(await clock.hasSynced == false, "a rejected sample must not feed the filter")
        #expect(await clock.totalSamplesAccepted == 0)
    }

    /// Only three of the four timestamps are wire-supplied; `client_received` is our own
    /// clock. So the remotely reachable crash is the RTT/offset math, while the filter's
    /// `dt` subtraction is reachable only via this API. Pins both.
    @Test("every Int64-extreme permutation of server/time is survivable")
    func allExtremePermutationsAreSurvivable() async {
        let extremes: [Int64] = [.min, .max, 0, -1, 1, .min + 1, .max - 1]
        let clock = ClockSynchronizer()

        for a in extremes {
            for b in extremes {
                await clock.processServerTime(
                    clientTransmitted: a,
                    serverReceived: b,
                    serverTransmitted: a,
                    clientReceived: b
                )
                await clock.processServerTime(
                    clientTransmitted: b,
                    serverReceived: a,
                    serverTransmitted: b,
                    clientReceived: a
                )
            }
        }

        // No accepted sample should leave the filter synchronized.
        #expect(await clock.hasSynced == false)
    }

    /// A well-formed sample remains accepted alongside the rejected boundary cases.
    @Test("a well-formed server/time sample is still accepted")
    func wellFormedSampleIsAccepted() async {
        let clock = ClockSynchronizer()
        let base: Int64 = 1_000_000_000

        // 10ms RTT, 5ms server-ahead offset.
        await clock.processServerTime(
            clientTransmitted: base,
            serverReceived: base + 5_000,
            serverTransmitted: base + 5_000,
            clientReceived: base + 10_000
        )

        #expect(await clock.lastSampleWasRejected == false, "a sane sample must pass the gate")
        #expect(await clock.totalSamplesAccepted == 1)
        #expect(await clock.latestAcceptedRtt == 10_000)
    }

    // MARK: - Time conversion

    /// `BinaryMessage` admits any non-negative timestamp and the color path converts it
    /// ungated by sync, so the epoch-anchor addition must saturate.
    @Test("serverTimeToLocal saturates on a huge timestamp instead of trapping")
    func serverTimeToLocalSaturates() async {
        let clock = ClockSynchronizer()

        _ = await clock.serverTimeToLocal(.max)
        _ = await clock.serverTimeToLocal(0)

        // Synced path: feed two good samples so `isSynchronized` opens, then convert.
        let base: Int64 = 1_000_000_000
        await clock.processServerTime(
            clientTransmitted: base,
            serverReceived: base + 1_000,
            serverTransmitted: base + 1_000,
            clientReceived: base + 2_000
        )
        await clock.processServerTime(
            clientTransmitted: base + 1_000_000,
            serverReceived: base + 1_001_000,
            serverTransmitted: base + 1_001_000,
            clientReceived: base + 1_002_000
        )

        _ = await clock.serverTimeToLocal(.max)
        _ = await clock.localTimeToServer(.min)
        _ = await clock.localTimeToServer(.max)

        #expect(await clock.hasSynced, "the good samples should have synced the filter")
    }

    // MARK: - PlaybackProgress

    @Test("currentPositionMs does not trap on an extreme server timestamp")
    func playbackProgressDoesNotTrapOnExtremeTimestamp() {
        for timestamp in [Int64.min, .max, .min + 1, .max - 1] {
            for speed in [0, 1_000, Int.max, Int.min] {
                let progress = PlaybackProgress(
                    trackProgressMs: 1_000,
                    trackDurationMs: 300_000,
                    playbackSpeedX1000: speed,
                    timestamp: timestamp
                )
                let position = progress.currentPositionMs(at: 0)
                #expect(position >= 0)
                #expect(position <= 300_000)
            }
        }
    }

    /// `trackDurationMs == 0` (live radio) has no upper clamp, so a wrapped `elapsed`
    /// surfaces to the consumer instead of being hidden. Unguarded, `Int64.min - 1`
    /// wraps to `Int64.max` and reports a position ~292 million years in.
    @Test("currentPositionMs reports the last known position when elapsed overflows")
    func playbackProgressRejectsWrappedElapsedWithUnknownDuration() {
        let progress = PlaybackProgress(
            trackProgressMs: 1_000,
            trackDurationMs: 0,
            playbackSpeedX1000: 1,
            timestamp: 1
        )

        #expect(progress.currentPositionMs(at: .min) == 1_000)
    }

    @Test("currentPositionMs does not trap for a live stream at Int64 extremes")
    func playbackProgressSurvivesExtremesWithUnknownDuration() {
        for timestamp in [Int64.min, .max, .min + 1, .max - 1] {
            for speed in [0, 1, 1_000, Int.max, Int.min] {
                let progress = PlaybackProgress(
                    trackProgressMs: 1_000,
                    trackDurationMs: 0,
                    playbackSpeedX1000: speed,
                    timestamp: timestamp
                )
                for now in [Int64.min, 0, .max] {
                    #expect(progress.currentPositionMs(at: now) >= 0)
                }
            }
        }
    }

    // MARK: - TimeFilterSnapshot (audio-thread conversions)

    /// The snapshot replicates `ClockSynchronizer`'s conversions for the real-time audio
    /// thread, where a trap is a crash. Its `Int64(exactly:)` guards do not cover the
    /// anchor add/subtract, so those must saturate.
    @Test("TimeFilterSnapshot conversions saturate instead of trapping")
    func timeFilterSnapshotConversionsSaturate() {
        for anchor in [Int64.min, 0, .max] {
            let snapshot = TimeFilterSnapshot(
                offset: 0,
                drift: 0,
                lastUpdate: 0,
                useDrift: false,
                clientProcessStartAbsolute: anchor
            )
            for value in [Int64.min, -1, 0, 1, .max] {
                _ = snapshot.serverTimeToLocal(value)
                _ = snapshot.localTimeToServer(value)
            }
        }

        // A normal-range conversion remains exact after the boundary cases.
        let sane = TimeFilterSnapshot(
            offset: 0,
            drift: 0,
            lastUpdate: 0,
            useDrift: false,
            clientProcessStartAbsolute: 1_000
        )
        #expect(sane.serverTimeToLocal(500) == 1_500)
        #expect(sane.localTimeToServer(1_500) == 500)
    }

    // MARK: - Saturating helpers

    @Test("saturating arithmetic clamps to the correct bound")
    func saturatingArithmeticClampsDirectionally() {
        #expect(Int64.max.saturatingAdding(1) == .max)
        #expect(Int64.min.saturatingAdding(-1) == .min)
        #expect(Int64.min.saturatingSubtracting(1) == .min)
        #expect(Int64.max.saturatingSubtracting(-1) == .max)
        // Non-overflowing operands must be exact, not clamped.
        #expect(Int64(5).saturatingAdding(3) == 8)
        #expect(Int64(5).saturatingSubtracting(8) == -3)
    }

    @Test("currentPositionMs still interpolates correctly for sane input")
    func playbackProgressInterpolatesNormally() {
        let progress = PlaybackProgress(
            trackProgressMs: 10_000,
            trackDurationMs: 300_000,
            playbackSpeedX1000: 1_000,
            timestamp: 5_000_000
        )

        // 2 seconds later at 1× → 12_000ms.
        #expect(progress.currentPositionMs(at: 7_000_000) == 12_000)
        let fast = PlaybackProgress(
            trackProgressMs: 10_000,
            trackDurationMs: 300_000,
            playbackSpeedX1000: 2_000,
            timestamp: 5_000_000
        )
        #expect(fast.currentPositionMs(at: 7_000_000) == 14_000)
    }
}
