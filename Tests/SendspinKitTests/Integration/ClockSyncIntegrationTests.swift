// ABOUTME: Integration tests for clock synchronization simulating real network conditions
// ABOUTME: Tests multiple sync rounds with varying network jitter and clock drift

import Foundation
@testable import SendspinKit
import Testing

struct ClockSyncIntegrationTests {
    @Test
    func syncConvergesOverMultipleRoundsWithNetworkJitter() async throws {
        let sync = ClockSynchronizer()

        // Simulate 10 rounds of clock sync with varying network conditions
        // Server is consistently 50 microseconds ahead
        let serverOffset: Int64 = 50

        // Fixed jitter sequence for deterministic results
        let jitterSequence: [Int64] = [3, 17, 8, 12, 1, 19, 6, 14, 10, 5]

        var offsets: [Int64] = []

        for round in 0 ..< 10 {
            let baseTime = Int64(round * 10_000)

            // Simulate symmetric network delay with deterministic jitter
            let networkDelay: Int64 = 100
            let jitter = jitterSequence[round]

            let clientTx = baseTime
            let serverRx = baseTime + networkDelay + jitter + serverOffset // Client to server + offset
            let serverTx = serverRx + 5 // 5 microsecond server processing time
            let clientRx = serverTx + networkDelay + jitter - serverOffset // Server to client

            await sync.processServerTime(
                clientTransmitted: clientTx,
                serverReceived: serverRx,
                serverTransmitted: serverTx,
                clientReceived: clientRx
            )

            let currentOffset = await sync.currentOffset
            offsets.append(currentOffset)
        }

        // After multiple rounds, offset should be reasonably close to true offset
        let finalOffset = try #require(offsets.last)
        #expect(finalOffset > 0 && finalOffset < 150) // Should detect some offset

        // Verify median filtering is working (offsets should be relatively stable)
        let lastFive = Array(offsets.suffix(5))
        let maxValue = try #require(lastFive.max())
        let minValue = try #require(lastFive.min())
        let maxVariation = maxValue - minValue
        #expect(maxVariation < 200) // Low variation indicates good filtering
    }

    @Test
    func timeConversionMaintainsBidirectionalAccuracy() async {
        let sync = ClockSynchronizer()

        // Initialize with known offset
        await sync.processServerTime(
            clientTransmitted: 1_000,
            serverReceived: 1_500,
            serverTransmitted: 1_505,
            clientReceived: 2_005
        )

        let testServerTime: Int64 = 10_000

        // Convert server time to local
        let localTime = await sync.serverTimeToLocal(testServerTime)

        // Convert back to server time
        let backToServer = await sync.localTimeToServer(localTime)

        // Should get back to original value (within rounding error)
        #expect(abs(backToServer - testServerTime) < 5)
    }

    @Test
    func handlesExtremeNetworkJitterGracefully() async {
        let sync = ClockSynchronizer()

        // Add samples with extreme outliers
        let samples: [(Int64, Int64, Int64, Int64)] = [
            (1_000, 1_100, 1_105, 1_205), // Normal: ~50us offset
            (2_000, 2_100, 2_105, 2_205), // Normal: ~50us offset
            (3_000, 5_000, 5_005, 8_005), // Extreme jitter: 2000us each way
            (4_000, 4_100, 4_105, 4_205), // Normal: ~50us offset
            (5_000, 5_100, 5_105, 5_205) // Normal: ~50us offset
        ]

        for (clientTransmitted, serverReceived, serverTransmitted, clientReceived) in samples {
            await sync.processServerTime(
                clientTransmitted: clientTransmitted,
                serverReceived: serverReceived,
                serverTransmitted: serverTransmitted,
                clientReceived: clientReceived
            )
        }

        let offset = await sync.currentOffset

        // Median should filter out the extreme outlier
        // Normal samples have ~50us offset, outlier has ~2500us offset
        #expect(offset < 200) // Should be close to normal samples, not outlier
    }

    @Test
    func clockDriftDetectionOverTime() async {
        let sync = ClockSynchronizer()

        // Simulate clock drift: offset changes gradually over time
        for drift in stride(from: 0, through: 100, by: 10) {
            let baseTime = Int64(drift * 1_000)
            let currentOffset = Int64(50 + drift) // Clock drifting apart

            let networkDelay: Int64 = 100

            let clientTx = baseTime
            let serverRx = baseTime + networkDelay + currentOffset
            let serverTx = serverRx + 5
            let clientRx = serverTx + networkDelay - currentOffset

            await sync.processServerTime(
                clientTransmitted: clientTx,
                serverReceived: serverRx,
                serverTransmitted: serverTx,
                clientReceived: clientRx
            )
        }

        let finalOffset = await sync.currentOffset

        // Should track the drift (offset increases from 50 to 150)
        #expect(finalOffset > 100) // Has tracked some of the drift
    }
}
