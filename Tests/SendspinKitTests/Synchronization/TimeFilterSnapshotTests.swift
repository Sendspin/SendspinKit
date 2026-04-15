// ABOUTME: Tests for TimeFilterSnapshot — the audio-thread-safe time conversion snapshot
// ABOUTME: Validates conversions, round-trip consistency, and parity with SendspinTimeFilter

@testable import SendspinKit
import Testing

struct TimeFilterSnapshotTests {
    // MARK: - Test fixtures

    /// A snapshot with a known offset of 5000μs, no drift, anchored at epoch 1_000_000μs.
    /// Filter last updated at process-relative time 500_000μs.
    static let knownSnapshot = TimeFilterSnapshot(
        offset: 5_000.0,
        drift: 0.0,
        lastUpdate: 500_000,
        useDrift: false,
        clientProcessStartAbsolute: 1_000_000
    )

    /// A snapshot with drift active: offset 5000μs, drift 0.001 μs/μs (1 ppm).
    /// Deliberately small drift — just enough to produce a measurable difference
    /// in conversion results. The parity tests use a much larger drift (0.1) to
    /// force the filter's SNR gate open.
    static let driftSnapshot = TimeFilterSnapshot(
        offset: 5_000.0,
        drift: 0.001,
        lastUpdate: 500_000,
        useDrift: true,
        clientProcessStartAbsolute: 1_000_000
    )

    /// A snapshot with a negative offset (client clock ahead of server).
    static let negativeOffsetSnapshot = TimeFilterSnapshot(
        offset: -3_000.0,
        drift: 0.0,
        lastUpdate: 500_000,
        useDrift: false,
        clientProcessStartAbsolute: 1_000_000
    )

    // MARK: - Known-value conversions (no drift)

    @Test
    func serverTimeToLocal_appliesOffsetAndAnchor() {
        // server_time = 510_000 in server domain
        // computeClientTime: (510_000 - 5_000 + 0) / 1.0 = 505_000 (process-relative)
        // + clientProcessStartAbsolute: 505_000 + 1_000_000 = 1_505_000
        let result = Self.knownSnapshot.serverTimeToLocal(510_000)
        #expect(result == 1_505_000)
    }

    @Test
    func localTimeToServer_removesAnchorAndAppliesOffset() {
        // localTime = 1_505_000 absolute
        // clientRelative = 1_505_000 - 1_000_000 = 505_000
        // computeServerTime: 505_000 + round(5_000 + 0) = 510_000
        let result = Self.knownSnapshot.localTimeToServer(1_505_000)
        #expect(result == 510_000)
    }

    // MARK: - Negative offset

    @Test
    func serverTimeToLocal_worksWithNegativeOffset() {
        // offset = -3_000 means client is ahead of server
        // server_time = 510_000
        // computeClientTime: (510_000 - (-3_000)) / 1.0 = 513_000 (process-relative)
        // + anchor: 513_000 + 1_000_000 = 1_513_000
        let result = Self.negativeOffsetSnapshot.serverTimeToLocal(510_000)
        #expect(result == 1_513_000)
    }

    @Test
    func localTimeToServer_worksWithNegativeOffset() {
        // localTime = 1_513_000
        // clientRelative = 1_513_000 - 1_000_000 = 513_000
        // computeServerTime: 513_000 + round(-3_000) = 510_000
        let result = Self.negativeOffsetSnapshot.localTimeToServer(1_513_000)
        #expect(result == 510_000)
    }

    // MARK: - Round-trip consistency

    @Test
    func roundTripsWithoutDriftWithinRoundingTolerance() {
        let serverTime: Int64 = 750_000
        let local = Self.knownSnapshot.serverTimeToLocal(serverTime)
        let roundTripped = Self.knownSnapshot.localTimeToServer(local)

        #expect(abs(roundTripped - serverTime) <= 1)
    }

    @Test
    func roundTripsWithDriftWithinRoundingTolerance() {
        let serverTime: Int64 = 750_000
        let local = Self.driftSnapshot.serverTimeToLocal(serverTime)
        let roundTripped = Self.driftSnapshot.localTimeToServer(local)

        // With drift the inverse math has a division, so rounding error up to 1μs
        #expect(abs(roundTripped - serverTime) <= 1)
    }

    @Test
    func roundTripsWithNegativeOffsetWithinRoundingTolerance() {
        let serverTime: Int64 = 750_000
        let local = Self.negativeOffsetSnapshot.serverTimeToLocal(serverTime)
        let roundTripped = Self.negativeOffsetSnapshot.localTimeToServer(local)

        #expect(abs(roundTripped - serverTime) <= 1)
    }

    // MARK: - Drift behavior

    @Test
    func driftAffectsTimeConversionWhenUseDriftIsTrue() {
        let serverTime: Int64 = 600_000

        let withoutDrift = Self.knownSnapshot.serverTimeToLocal(serverTime)
        let withDrift = Self.driftSnapshot.serverTimeToLocal(serverTime)

        // With drift of 0.001 and a dt from lastUpdate, the results should differ
        #expect(withoutDrift != withDrift)
    }

    @Test
    func driftIsIgnoredWhenUseDriftIsFalse() {
        // Two snapshots with different drift values but both useDrift=false
        let snap1 = TimeFilterSnapshot(
            offset: 5_000.0, drift: 0.0, lastUpdate: 500_000,
            useDrift: false, clientProcessStartAbsolute: 1_000_000
        )
        let snap2 = TimeFilterSnapshot(
            offset: 5_000.0, drift: 0.5, lastUpdate: 500_000,
            useDrift: false, clientProcessStartAbsolute: 1_000_000
        )

        let serverTime: Int64 = 600_000
        #expect(snap1.serverTimeToLocal(serverTime) == snap2.serverTimeToLocal(serverTime))
        #expect(snap1.localTimeToServer(1_600_000) == snap2.localTimeToServer(1_600_000))
    }

    // MARK: - Parity with SendspinTimeFilter

    /// Build a snapshot from the current filter state with a fixed epoch anchor.
    private static func makeSnapshot(
        from filter: SendspinTimeFilter,
        anchor: Int64 = 1_000_000
    ) -> TimeFilterSnapshot {
        TimeFilterSnapshot(
            offset: filter.offset,
            drift: filter.drift,
            lastUpdate: filter.lastUpdate,
            useDrift: filter.useDrift,
            clientProcessStartAbsolute: anchor
        )
    }

    @Test
    func serverTimeToLocal_matchesFilterComputeClientTimePlusAnchor() {
        var filter = SendspinTimeFilter()
        for i in 0 ..< 20 {
            let t = Int64((i + 1) * 100_000)
            filter.update(timeAdded: t, measurement: 3_000.0, maxError: 25.0)
        }

        let anchor: Int64 = 1_000_000
        let snapshot = Self.makeSnapshot(from: filter, anchor: anchor)

        for serverTime: Int64 in [500_000, 1_000_000, 2_000_000, 5_000_000] {
            let fromFilter = filter.computeClientTime(serverTime) + anchor
            let fromSnapshot = snapshot.serverTimeToLocal(serverTime)
            #expect(
                fromFilter == fromSnapshot,
                "Snapshot and filter should agree for serverTime \(serverTime)"
            )
        }
    }

    @Test
    func localTimeToServer_matchesFilterComputeServerTimeWithAnchorRemoved() {
        var filter = SendspinTimeFilter()
        for i in 0 ..< 20 {
            let t = Int64((i + 1) * 100_000)
            filter.update(timeAdded: t, measurement: 3_000.0, maxError: 25.0)
        }

        let anchor: Int64 = 1_000_000
        let snapshot = Self.makeSnapshot(from: filter, anchor: anchor)

        for localTime: Int64 in [1_500_000, 2_000_000, 3_000_000, 6_000_000] {
            let clientRelative = localTime - anchor
            let fromFilter = filter.computeServerTime(clientRelative)
            let fromSnapshot = snapshot.localTimeToServer(localTime)
            #expect(
                fromFilter == fromSnapshot,
                "Snapshot and filter should agree for localTime \(localTime)"
            )
        }
    }

    @Test
    func parityWithFilterWhenDriftIsActive() {
        // Override the default threshold (2.0) with 0.1 and use a large drift (0.1 μs/μs)
        // to ensure drift² >> threshold² × driftCovariance, forcing useDrift = true.
        var filter = SendspinTimeFilter(driftSignificanceThreshold: 0.1)
        let trueDrift = 0.1

        for i in 0 ..< 100 {
            let t = Int64((i + 1) * 10_000)
            let measuredOffset = 2_000.0 + trueDrift * Double(t)
            filter.update(timeAdded: t, measurement: measuredOffset, maxError: 5.0)
        }

        #expect(filter.useDrift)

        let anchor: Int64 = 1_000_000
        let snapshot = Self.makeSnapshot(from: filter, anchor: anchor)

        for serverTime: Int64 in [500_000, 1_000_000, 2_000_000] {
            let fromFilter = filter.computeClientTime(serverTime) + anchor
            let fromSnapshot = snapshot.serverTimeToLocal(serverTime)
            #expect(
                fromFilter == fromSnapshot,
                "serverTimeToLocal mismatch with drift for serverTime \(serverTime)"
            )
        }

        for localTime: Int64 in [1_500_000, 2_000_000, 3_000_000] {
            let clientRelative = localTime - anchor
            let fromFilter = filter.computeServerTime(clientRelative)
            let fromSnapshot = snapshot.localTimeToServer(localTime)
            #expect(
                fromFilter == fromSnapshot,
                "localTimeToServer mismatch with drift for localTime \(localTime)"
            )
        }
    }
}
