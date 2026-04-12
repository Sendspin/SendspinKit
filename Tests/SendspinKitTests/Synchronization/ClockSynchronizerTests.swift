@testable import SendspinKit
import Testing

struct ClockSynchronizerTests {
    @Test
    func `Calculate offset from server time`() async {
        let sync = ClockSynchronizer()

        // Simulate NTP exchange where server clock is 100 microseconds ahead
        let clientTx: Int64 = 1_000
        // Client sent at 1000, server clock reads 1150 (server ahead by 100, plus 50 network delay)
        let serverRx: Int64 = 1_150
        let serverTx: Int64 = 1_155 // +5 processing
        let clientRx: Int64 = 1_205 // Client receives at 1205 (50 network delay back)

        await sync.processServerTime(
            clientTransmitted: clientTx,
            serverReceived: serverRx,
            serverTransmitted: serverTx,
            clientReceived: clientRx
        )

        let offset = await sync.currentOffset

        // Expected offset: ((serverRx - clientTx) + (serverTx - clientRx)) / 2
        // = ((1150 - 1000) + (1155 - 1205)) / 2
        // = (150 + (-50)) / 2 = 100 / 2 = 50
        // But we want to demonstrate server ahead by ~100, so let's recalculate
        // If server is 100 ahead and symmetric 50us delays:
        // clientTx=1000, arrives at server at 1050 server time (but server ahead by 100, so shows 1150)
        // Actually the offset formula gives us: (150 - 50) / 2 = 50
        #expect(offset == 50)
    }

    @Test
    func `Use median of multiple samples`() async {
        let sync = ClockSynchronizer()

        // Add samples where server is consistently ahead by ~100, with one outlier
        // Each sample: server ahead by 100, symmetric 50us delays
        // offset = 50
        await sync.processServerTime(
            clientTransmitted: 1_000, serverReceived: 1_150, serverTransmitted: 1_155, clientReceived: 1_205
        )
        // offset = 50
        await sync.processServerTime(
            clientTransmitted: 2_000, serverReceived: 2_150, serverTransmitted: 2_155, clientReceived: 2_205
        )
        // offset = 250 (outlier - high jitter)
        await sync.processServerTime(
            clientTransmitted: 3_000, serverReceived: 3_600, serverTransmitted: 3_605, clientReceived: 3_705
        )
        // offset = 50
        await sync.processServerTime(
            clientTransmitted: 4_000, serverReceived: 4_150, serverTransmitted: 4_155, clientReceived: 4_205
        )

        let offset = await sync.currentOffset

        // With drift compensation, offset should be close to measured values (~50)
        // Allow tolerance for Kalman filter smoothing
        #expect(offset >= 40 && offset <= 100)
    }

    @Test
    func `Convert server time to local time`() async {
        let sync = ClockSynchronizer()

        // Server ahead by 200, symmetric 100us delays
        await sync.processServerTime(
            clientTransmitted: 1_000,
            serverReceived: 1_300, // 1000 + 100 delay + 200 offset
            serverTransmitted: 1_305,
            clientReceived: 1_405 // 1305 + 100 delay
        )
        // offset = ((1300-1000) + (1305-1405)) / 2 = (300 + -100) / 2 = 100

        let serverTime: Int64 = 5_000
        let localTime = await sync.serverTimeToLocal(serverTime)

        // serverTimeToLocal now returns absolute Unix epoch time, not relative time
        // It should be: serverLoopOriginAbsolute + serverTime
        // We can't test exact value since it depends on when test runs,
        // but we can verify it's a reasonable absolute timestamp (> server time)
        #expect(localTime > serverTime)
    }

    @Test
    func `Snapshot produces identical conversions as actor methods`() async {
        let sync = ClockSynchronizer()

        // Feed enough samples to get a stable filter with drift
        await sync.processServerTime(
            clientTransmitted: 1_000, serverReceived: 1_150,
            serverTransmitted: 1_155, clientReceived: 1_205
        )
        await sync.processServerTime(
            clientTransmitted: 2_000, serverReceived: 2_150,
            serverTransmitted: 2_155, clientReceived: 2_205
        )
        await sync.processServerTime(
            clientTransmitted: 3_000, serverReceived: 3_150,
            serverTransmitted: 3_155, clientReceived: 3_205
        )

        let snap = await sync.snapshot()
        #expect(snap.isValid)

        // Test serverTimeToLocal matches for several server times
        for serverTime: Int64 in [0, 1_000, 5_000, 100_000, 1_000_000] {
            let actorResult = await sync.serverTimeToLocal(serverTime)
            let snapResult = snap.serverTimeToLocal(serverTime)
            #expect(
                actorResult == snapResult,
                "serverTimeToLocal mismatch for serverTime=\(serverTime): actor=\(actorResult) snapshot=\(snapResult)"
            )
        }

        // Test localToServerTime matches for several local times
        // Use a recent absolute time as base
        let baseLocal = await sync.serverTimeToLocal(3_000)
        for delta: Int64 in [0, 1_000, 5_000, -1_000] {
            let localTime = baseLocal + delta
            let actorResult = await sync.localTimeToServer(localTime)
            let snapResult = snap.localToServerTime(localTime)
            #expect(
                actorResult == snapResult,
                "localToServerTime mismatch for localTime delta=\(delta): actor=\(actorResult) snapshot=\(snapResult)"
            )
        }
    }

    @Test
    func `Snapshot is invalid before first sync`() async {
        let sync = ClockSynchronizer()
        let snap = await sync.snapshot()
        #expect(!snap.isValid)
        #expect(snap.serverTimeToLocal(5_000) == 0)
        #expect(snap.localToServerTime(5_000) == 0)
    }
}
