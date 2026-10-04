@testable import SendspinKit
import Testing

struct OutputRebuildCorrectionTests {
    @Test func stopResetsReadinessBeforeNextCorrectionPass() async throws {
        let format = try AudioFormatSpec(codec: .pcm, channels: 2, sampleRate: 48_000, bitDepth: 16)
        let player = AudioPlayer()
        let capacity = Int(audioQueueBufferByteSize)
        let frameSize = format.channels * (format.bitDepth / 8)
        let cadence = UInt32(capacity / frameSize)
        player.lockedState.withLock { state in
            state.prewarming = false
            state.queueStartAbsoluteUs = MonotonicClock.absoluteMicroseconds()
            state.spinUpUs = 0
            state.lastSyncErrorUs = audioQueueTeardownSlowThresholdUs
        }
        let ready = await player.telemetrySnapshot
        #expect(ready.syncErrorUs == audioQueueTeardownSlowThresholdUs)

        await player.stop()
        player.lockedState.withLock { state in
            state.correctionSchedule = CorrectionSchedule(insertEveryNFrames: cadence, dropEveryNFrames: cadence)
            state.dropCounter = cadence
            state.insertCounter = cadence
            AudioPlayer.updateCorrectionSchedule(
                state: &state, capacity: capacity, frameSize: frameSize,
                sampleRate: format.sampleRate, inFlightAtCallback: nil
            )
            #expect(state.correctionSchedule == CorrectionSchedule())
            #expect(state.dropCounter == 0)
            #expect(state.insertCounter == 0)
        }
        let stopped = await player.telemetrySnapshot
        #expect(stopped.syncErrorUs == nil)
        #expect(stopped.correctionSchedule == CorrectionSchedule())
    }

    @Test func staleCursorDoesNotDriveCorrectionUntilOutputIsReady() throws {
        let format = try AudioFormatSpec(codec: .pcm, channels: 2, sampleRate: 48_000, bitDepth: 16)
        let capacity = Int(audioQueueBufferByteSize)
        let frameSize = format.channels * (format.bitDepth / 8)
        var state = LockedState(pcmRingBuffer: PCMRingBuffer(capacity: capacity))
        defer { state.deallocateResources() }
        state.sampleRate = format.sampleRate
        state.cursorMicroseconds = Int64(format.sampleRate)
        state.timeSnapshot = TimeFilterSnapshot(
            offset: 0, drift: 0, lastUpdate: 0, useDrift: false, clientProcessStartAbsolute: 0
        )
        let sentinelError = Int64(audioQueueTeardownSlowThresholdUs)
        state.lastSyncErrorUs = sentinelError
        state.correctionGraceFrames = Int64(format.sampleRate)
        let cadence = UInt32(capacity / frameSize)

        for phase in 0 ... 2 {
            state.queueStartAbsoluteUs = phase == 0 ? 0 : MonotonicClock.absoluteMicroseconds()
            state.prewarming = phase != 2
            state.spinUpUs = -1
            state.correctionSchedule = CorrectionSchedule(insertEveryNFrames: cadence, dropEveryNFrames: cadence)
            state.dropCounter = cadence
            state.insertCounter = cadence
            AudioPlayer.updateCorrectionSchedule(
                state: &state, capacity: capacity, frameSize: frameSize,
                sampleRate: format.sampleRate, inFlightAtCallback: nil
            )
            #expect(state.correctionSchedule == CorrectionSchedule())
            #expect(state.dropCounter == 0)
            #expect(state.insertCounter == 0)
            #expect(state.lastSyncErrorUs == sentinelError)
            #expect(state.correctionGraceFrames == Int64(format.sampleRate))
            #expect(state.telemetrySyncErrorUs == nil)
        }

        state.spinUpUs = 0
        AudioPlayer.updateCorrectionSchedule(
            state: &state, capacity: capacity, frameSize: frameSize,
            sampleRate: format.sampleRate, inFlightAtCallback: nil
        )
        #expect(state.lastSyncErrorUs != sentinelError)
        #expect(state.telemetrySyncErrorUs == state.lastSyncErrorUs)
        #expect(state.correctionGraceFrames == Int64(format.sampleRate - capacity / frameSize))
    }

    @Test func telemetryReportsPendingForStoppedQueueAndNumberAfterReadiness() async {
        let player = AudioPlayer()
        let stopped = await player.telemetrySnapshot
        #expect(stopped.syncErrorUs == nil)
        #expect(stopped.correctionSchedule == CorrectionSchedule())

        var state = LockedState(pcmRingBuffer: PCMRingBuffer(capacity: Int(audioQueueBufferByteSize)))
        defer { state.deallocateResources() }
        state.lastSyncErrorUs = audioQueueTeardownSlowThresholdUs
        #expect(state.telemetrySyncErrorUs == nil)
        state.queueStartAbsoluteUs = MonotonicClock.absoluteMicroseconds()
        state.prewarming = false
        #expect(state.telemetrySyncErrorUs == nil)
        state.spinUpUs = 0
        #expect(state.telemetrySyncErrorUs == audioQueueTeardownSlowThresholdUs)
    }
}
