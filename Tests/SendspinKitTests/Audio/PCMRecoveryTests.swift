import Foundation
@testable import SendspinKit
import Testing

struct PCMRecoveryTests {
    private func state(rate: Int = 1_000, capacity: Int = 32_768) -> AudioRenderState {
        var state = AudioRenderState(pcmRingBuffer: PCMRingBuffer(capacity: capacity))
        state.sampleRate = rate
        state.frameSize = MemoryLayout<Int16>.size
        state.prewarming = false
        state.timeSnapshot = TimeFilterSnapshot(
            offset: 0, drift: 0, lastUpdate: 0, useDrift: false, clientProcessStartAbsolute: 0
        )
        return state
    }

    @discardableResult
    private func enqueue(_ ids: [Int16], at timestamp: Int64, into state: inout AudioRenderState) -> Int {
        ids.withUnsafeBytes { state.enqueuePCM(Data($0), serverTimestamp: timestamp) }
    }

    private func render(_ state: inout AudioRenderState, now: Int64, frames: Int, depth: Int64 = 175) -> [Int16] {
        state.updateCorrectionSchedule(
            localNow: now, capacity: frames * state.frameSize, frameSize: state.frameSize,
            sampleRate: state.sampleRate, inFlightAtCallback: depth
        )
        var output = [Int16](repeating: 0, count: frames)
        output.withUnsafeMutableBytes {
            _ = state.fillFrames(into: $0.baseAddress!.assumingMemoryBound(to: UInt8.self), capacity: $0.count)
        }
        return output
    }

    @Test func fullFutureWaitEndsInsideBufferWithoutConsumingSource() {
        var state = state()
        defer { state.deallocateResources() }
        enqueue([11, 12, 13], at: 1_500_000, into: &state)
        for index in 0 ..< 6 {
            #expect(render(&state, now: 1_000_000 + Int64(index) * 50_000, frames: 50) == Array(repeating: 0, count: 50))
            #expect(state.cursorMicroseconds == 1_500_000)
            #expect(state.framesConsumed == 0)
        }
        let output = render(&state, now: 1_300_000, frames: 50)
        #expect(Array(output.prefix(25)) == Array(repeating: 0, count: 25))
        #expect(Array(output[25 ..< 28]) == [11, 12, 13])
        #expect(state.framesConsumed == 3)
    }

    @Test func currentReanchorDiscardsOnlyStalePrefixAndKeepsFutureReserve() {
        var state = state()
        defer { state.deallocateResources() }
        enqueue([1, 2, 3], at: 1_000_000, into: &state)
        enqueue([21, 22, 23], at: 2_000_000, into: &state)
        state.reanchorRequested = true
        state.pendingReanchorServerTime = 9_000_000
        #expect(render(&state, now: 1_500_000, frames: 50).allSatisfy { $0 == 0 })
        #expect(state.cursorMicroseconds == 2_000_000)
        #expect(state.pcmRingBuffer.availableToRead == 6)
        #expect(state.flowDiagnostics.clearedFrames == 3)
        #expect(Array(render(&state, now: 1_825_000, frames: 3).prefix(3)) == [21, 22, 23])
    }

    @Test func producerStallThenAheadChunksRecoverAcrossSeconds() {
        var state = state()
        defer { state.deallocateResources() }
        enqueue(Array(repeating: 7, count: 100), at: 1_175_000, into: &state)
        #expect(render(&state, now: 1_000_000, frames: 100).allSatisfy { $0 == 7 })
        for index in 0 ..< 26 {
            #expect(render(&state, now: 1_100_000 + Int64(index) * 50_000, frames: 50).allSatisfy { $0 == 0 })
        }
        let resume: Int64 = 2_419_000
        for index in 0 ..< 60 {
            let now = resume + Int64(index) * 50_000
            let id = Int16(100 + index)
            enqueue(Array(repeating: id, count: 50), at: now + 500_000, into: &state)
            let output = render(&state, now: now, frames: 50)
            if index < 6 {
                #expect(output.allSatisfy { $0 == 0 })
            }
            if index >= 7 {
                #expect(output.first == Int16(100 + index - 7))
                #expect(output.last == Int16(100 + index - 6))
            }
        }
        #expect(state.flowDiagnostics.correctionDrops == 0)
        #expect(state.pcmRingBuffer.availableToRead > 0)
    }

    @Test func clearNewGenerationAndPartialOverflowKeepByteTimestampConservation() {
        var state = state(capacity: 8)
        defer { state.deallocateResources() }
        #expect(enqueue([1, 2, 3], at: 1_000_000, into: &state) == 6)
        #expect(enqueue([9, 10, 11], at: 2_000_000, into: &state) == 2)
        #expect(render(&state, now: 1_000_000, frames: 3, depth: 0) == [1, 2, 3])
        #expect(state.cursorMicroseconds == 2_000_000)
        let generation = state.mappingGeneration
        state.clearPCM()
        #expect(state.mappingGeneration == generation + 1)
        #expect(!state.lastFrameValid)
        #expect(state.timestampSpans.count == 0)
        enqueue([31, 32], at: 3_000_000, into: &state)
        #expect(render(&state, now: 2_500_000, frames: 50).allSatisfy { $0 == 0 })
        #expect(state.cursorMicroseconds == 3_000_000)
        #expect(render(&state, now: 3_000_000, frames: 2, depth: 0) == [31, 32])
    }

    @Test func staleRefillSkipsOnlyExpiredFrames() {
        var state = state()
        defer { state.deallocateResources() }
        enqueue([1, 2, 3, 4], at: 1_000_000, into: &state)
        #expect(render(&state, now: 1_002_000, frames: 2, depth: 0) == [3, 4])
        #expect(state.flowDiagnostics.clearedFrames == 2)
        #expect(state.cursorMicroseconds == 1_004_000)
    }

    @Test func timestampedDropInsertAndUnderrunKeepSourceIdentity() {
        var state = state()
        defer { state.deallocateResources() }
        enqueue([1, 2, 3, 4, 5, 6], at: 1_000_000, into: &state)
        _ = render(&state, now: 1_000_000, frames: 1, depth: 0)
        state.correctionSchedule = CorrectionSchedule(dropEveryNFrames: 2)
        state.dropCounter = 2
        var output = [Int16](repeating: 0, count: 2)
        output.withUnsafeMutableBytes {
            _ = state.fillFrames(into: $0.baseAddress!.assumingMemoryBound(to: UInt8.self), capacity: $0.count)
        }
        #expect(output == [2, 4])
        #expect(state.cursorMicroseconds == 1_004_000)
        state.updateCorrectionSchedule(
            localNow: 1_004_000, capacity: 4, frameSize: state.frameSize,
            sampleRate: state.sampleRate, inFlightAtCallback: 0
        )
        state.correctionSchedule = CorrectionSchedule(insertEveryNFrames: 2)
        state.insertCounter = 1
        output.withUnsafeMutableBytes {
            _ = state.fillFrames(into: $0.baseAddress!.assumingMemoryBound(to: UInt8.self), capacity: $0.count)
        }
        #expect(output == [4, 5])
        #expect(state.cursorMicroseconds == 1_005_000)
        #expect(render(&state, now: 1_005_000, frames: 3, depth: 0) == [6, 0, 0])
        #expect(state.cursorMicroseconds == 1_006_000)
        #expect(state.timestampSpans.count == 0)
    }

    @Test func metadataSlotExhaustionRejectsBytesUntilARepresentedPrefixFits() {
        var state = state(capacity: 32_768)
        defer { state.deallocateResources() }
        for index in 0 ..< state.timestampSpans.capacity {
            #expect(enqueue([1], at: 1_000_000 + Int64(index) * 2_000, into: &state) == 2)
        }
        let bytes = state.pcmRingBuffer.availableToRead
        #expect(enqueue([99], at: 99_000_000, into: &state) == 0)
        #expect(state.pcmRingBuffer.availableToRead == bytes)
        #expect(state.pcmRingBuffer.availableToWrite > 0)
    }

    @Test func currentSnapshotAndDelayMoveEligibilityWithoutRelabelingSource() {
        var state = state()
        defer { state.deallocateResources() }
        let samples: [Int16] = [41, 42]
        samples.withUnsafeBytes {
            #expect(state.enqueuePCM(Data($0), serverTimestamp: 2_000_000, localPlayTime: 2_100_000, timelineAdjustmentUs: 100_000) == $0.count)
        }
        state.timeSnapshot = TimeFilterSnapshot(
            offset: 100_000, drift: 0, lastUpdate: 0, useDrift: false, clientProcessStartAbsolute: 0
        )
        state.outputDelayUs = 50_000
        #expect(render(&state, now: 1_949_000, frames: 3, depth: 0) == [0, 41, 42])
        #expect(state.cursorMicroseconds == 2_002_000)
    }

    @Test func futureDrainRetainsPCMInsteadOfClaimingCompletionOrPlayingEarly() {
        var state = state()
        defer { state.deallocateResources() }
        state.draining = true
        enqueue([9, 10], at: 5_000_000, into: &state)
        for index in 0 ..< 40 {
            #expect(render(&state, now: 1_000_000 + Int64(index) * 50_000, frames: 50).allSatisfy { $0 == 0 })
        }
        #expect(state.pcmRingBuffer.availableToRead == 4)
        #expect(state.framesConsumed == 0)
        #expect(!state.drainComplete)
    }

    @Test func driftMapsFutureWaitAtOutputOffset() {
        var state = state()
        defer { state.deallocateResources() }
        state.timeSnapshot = TimeFilterSnapshot(
            offset: 0, drift: 0.1, lastUpdate: 0, useDrift: true, clientProcessStartAbsolute: 0
        )
        enqueue([51, 52], at: 1_111_000, into: &state)
        #expect(render(&state, now: 1_000_000, frames: 12, depth: 0) == Array(repeating: 0, count: 10) + [51, 52])
    }

    @Test func contiguousSpansMergeButDiscontinuitiesRemainOrdered() {
        var state = state()
        defer { state.deallocateResources() }
        enqueue([1, 2], at: 1_000_000, into: &state)
        enqueue([3, 4], at: 1_002_000, into: &state)
        #expect(state.timestampSpans.count == 1)
        enqueue([9], at: 2_000_000, into: &state)
        #expect(state.timestampSpans.count == 2)
        #expect(render(&state, now: 1_000_000, frames: 6, depth: 0) == [1, 2, 3, 4, 0, 0])
        #expect(state.cursorMicroseconds == 2_000_000)
        #expect(state.pcmRingBuffer.availableToRead == 2)
    }

    @Test func fractionalTrimPartitioningHasSameNextSourceIdentity() {
        var one = state(rate: 44_100)
        var partitioned = state(rate: 44_100)
        defer {
            one.deallocateResources()
            partitioned.deallocateResources()
        }
        enqueue([1, 2, 3, 4, 5], at: 1_000_000, into: &one)
        enqueue([1, 2, 3, 4, 5], at: 1_000_000, into: &partitioned)
        one.trimStalePCM(at: 1_000_046)
        partitioned.trimStalePCM(at: 1_000_022)
        partitioned.trimStalePCM(at: 1_000_023)
        partitioned.trimStalePCM(at: 1_000_046)
        #expect(one.cursorMicroseconds == partitioned.cursorMicroseconds)
        #expect(one.cursorRemainder == partitioned.cursorRemainder)
        #expect(one.framesConsumed == 3)
        #expect(partitioned.framesConsumed == 3)
        #expect(render(&one, now: 1_000_069, frames: 2, depth: 0) == [4, 5])
        #expect(render(&partitioned, now: 1_000_069, frames: 2, depth: 0) == [4, 5])
    }

    @Test func roundedAdjacentChunksPreserveRationalPhase() {
        var partitioned = state(rate: 44_100)
        var whole = state(rate: 44_100)
        defer {
            partitioned.deallocateResources()
            whole.deallocateResources()
        }
        let ids = (1 ... 64).map(Int16.init)
        enqueue(ids, at: 1_000_000, into: &whole)
        for index in ids.indices {
            let timestamp = 1_000_000 + Int64((Double(index) * 1_000_000 / 44_100).rounded())
            enqueue([ids[index]], at: timestamp, into: &partitioned)
        }
        #expect(render(&partitioned, now: 1_000_000, frames: ids.count, depth: 0)
            == render(&whole, now: 1_000_000, frames: ids.count, depth: 0))
        #expect(partitioned.cursorMicroseconds == whole.cursorMicroseconds)
        #expect(partitioned.cursorRemainder == whole.cursorRemainder)
    }

    @Test func continuousChunkBoundariesDoNotResetLongCorrectionCadence() {
        var state = state(rate: 44_100)
        defer { state.deallocateResources() }
        enqueue(Array(repeating: 1, count: 1_024), at: 1_000_000, into: &state)
        enqueue(Array(repeating: 2, count: 1_024), at: 1_023_220, into: &state)
        enqueue(Array(repeating: 3, count: 1_024), at: 1_046_440, into: &state)
        _ = render(&state, now: 1_000_000, frames: 1, depth: 0)
        state.correctionSchedule = CorrectionSchedule(dropEveryNFrames: 2_000)
        state.dropCounter = 2_000
        var output = [Int16](repeating: 0, count: 2_500)
        output.withUnsafeMutableBytes {
            _ = state.fillFrames(into: $0.baseAddress!.assumingMemoryBound(to: UInt8.self), capacity: $0.count)
        }
        #expect(state.flowDiagnostics.correctionDrops == 1)
        #expect(state.framesConsumed == 2_502)
    }

    @Test func yieldedWireChunkUsesClockAndDelayAtEnqueueNotCachedPlayTime() {
        var state = state()
        defer { state.deallocateResources() }
        let cachedPlayTime: Int64 = 2_000_000
        state.timeSnapshot = TimeFilterSnapshot(
            offset: 100_000, drift: 0, lastUpdate: 0, useDrift: false, clientProcessStartAbsolute: 0
        )
        state.outputDelayUs = 50_000
        let ids: [Int16] = [71, 72]
        ids.withUnsafeBytes {
            #expect(state.enqueuePCM(Data($0), serverTimestamp: 2_000_000, localPlayTime: cachedPlayTime) == $0.count)
        }
        #expect(render(&state, now: 1_849_000, frames: 3, depth: 0) == [0, 71, 72])
    }

    @Test func drainedChunksRetainFractionalPhaseAndLegitimateGapStillWaits() {
        var state = state(rate: 44_100)
        defer { state.deallocateResources() }
        for index in 0 ..< 32 {
            let timestamp = 1_000_000 + Int64((Double(index) * 1_000_000 / 44_100).rounded())
            enqueue([Int16(index + 1)], at: timestamp, into: &state)
            #expect(render(&state, now: 1_000_000 + Int64(index) * 1_000_000 / 44_100, frames: 1, depth: 0) == [Int16(index + 1)])
        }
        #expect(state.cursorMicroseconds == 1_000_000 + 32 * 1_000_000 / 44_100)
        #expect(state.cursorRemainder == 32 * 1_000_000 % 44_100)
        let next = state.cursorMicroseconds
        enqueue([99], at: next + 10, into: &state)
        #expect(render(&state, now: next, frames: 2, depth: 0) == [0, 99])
    }

    @Test func extremeTimestampPolicyRejectsUnrepresentableEndpointsWithoutOrphanBytes() {
        var state = state(rate: 44_100)
        defer { state.deallocateResources() }
        #expect(enqueue([1], at: .max, into: &state) == 0)
        #expect(state.pcmRingBuffer.availableToRead == 0)
        #expect(state.timestampSpans.count == 0)
        #expect(enqueue([2], at: .max - 100, into: &state) == 2)
        #expect(enqueue([3], at: .max - 77, into: &state) == 2)
        #expect(state.timestampSpans.count == 1)
        #expect(render(&state, now: .max - 100, frames: 4, depth: 0).prefix(2) == [2, 3])
        state.clearPCM()
        #expect(enqueue([4, 5], at: .min, into: &state) == 4)
        #expect(state.pcmRingBuffer.availableToRead == 4)
        state.trimStalePCM(at: .max)
        #expect(state.pcmRingBuffer.availableToRead == 0)
        #expect(state.timestampSpans.count == 0)
    }

    @Test func extremeRenderTimeAndAdjustmentSaturateWithoutRelabeling() {
        var state = state()
        defer { state.deallocateResources() }
        let ids: [Int16] = [81]
        ids.withUnsafeBytes {
            #expect(state.enqueuePCM(Data($0), serverTimestamp: 1_000_000, timelineAdjustmentUs: .max) == 2)
        }
        #expect(render(&state, now: .max - 1_000, frames: 4, depth: 175).count == 4)
        #expect(state.cursorMicroseconds == 1_000_000)
    }

    @Test func schedulerYieldCarriesOnlyExplicitDecodedTimelineAdjustment() async throws {
        let scheduler = AudioScheduler(clockSync: StubClock(), now: { 2_000_000 })
        let ids: [Int16] = [91, 92]
        let pcm = ids.withUnsafeBytes { Data($0) }
        await scheduler.schedule(pcm: pcm, serverTimestamp: 2_000_000, playTimeMicroseconds: 2_000_000)
        await scheduler.checkQueue()
        let stream = await scheduler.scheduledChunks
        var iterator = stream.makeAsyncIterator()
        let wire = try #require(await iterator.next())
        #expect(wire.timelineAdjustmentUs == nil)
        var state = state()
        defer { state.deallocateResources() }
        state.timeSnapshot = TimeFilterSnapshot(
            offset: 100_000, drift: 0, lastUpdate: 0, useDrift: false, clientProcessStartAbsolute: 0
        )
        state.outputDelayUs = 50_000
        #expect(state.enqueuePCM(
            wire.pcmData, serverTimestamp: wire.originalTimestamp,
            localPlayTime: wire.playTimeMicroseconds, timelineAdjustmentUs: wire.timelineAdjustmentUs
        ) == pcm.count)
        #expect(render(&state, now: 1_849_000, frames: 3, depth: 0) == [0, 91, 92])
        await scheduler.schedule(
            pcm: pcm, serverTimestamp: 2_000_000, playTimeMicroseconds: 2_000_000,
            timelineAdjustmentUs: 1_234
        )
        await scheduler.checkQueue()
        #expect(try #require(await iterator.next()).timelineAdjustmentUs == 1_234)
        await scheduler.finish()
    }

    @Test func continuousRefillAfterUnderrunTrimsStalePrefixDuringGrace() {
        var state = state()
        defer { state.deallocateResources() }
        state.correctionGraceFrames = 1_000
        enqueue([1], at: 1_000_000, into: &state)
        #expect(render(&state, now: 1_000_000, frames: 1, depth: 0) == [1])
        #expect(render(&state, now: 1_001_000, frames: 200, depth: 0).allSatisfy { $0 == 0 })
        #expect(state.cursorMicroseconds == 1_001_000)
        enqueue((2 ... 251).map(Int16.init), at: 1_001_000, into: &state)
        #expect(render(&state, now: 1_201_000, frames: 10, depth: 0) == (202 ... 211).map(Int16.init))
        #expect(state.correctionGraceFrames > 0)
        #expect(state.flowDiagnostics.clearedFrames == 200)
        #expect(state.flowDiagnostics.correctionDrops == 0)
        #expect(state.cursorMicroseconds == 1_211_000)
        #expect(state.pcmRingBuffer.availableToRead == 40 * state.frameSize)
        #expect(render(&state, now: 1_211_000, frames: 10, depth: 0) == (212 ... 221).map(Int16.init))
    }

    @Test func timelyEmptyRefillPreservesFractionalPhaseAndCorrectionCadence() {
        var state = state(rate: 44_100)
        defer { state.deallocateResources() }
        enqueue([1], at: 1_000_000, into: &state)
        #expect(render(&state, now: 1_000_000, frames: 1, depth: 0) == [1])
        let schedule = CorrectionSchedule(dropEveryNFrames: 2_000)
        state.correctionSchedule = schedule
        state.dropCounter = 1_234
        state.insertCounter = 17
        let reanchors = state.flowDiagnostics.reanchors
        enqueue([2, 3], at: 1_000_023, into: &state)
        #expect(state.cursorMicroseconds == 1_000_022)
        #expect(state.cursorRemainder == 29_800)
        state.trimStalePCM(at: 1_000_022)
        #expect(state.correctionSchedule == schedule)
        #expect(state.dropCounter == 1_234)
        #expect(state.insertCounter == 17)
        #expect(state.lastFrameValid)
        #expect(state.flowDiagnostics.reanchors == reanchors)
        var output = [Int16](repeating: 0, count: 2)
        output.withUnsafeMutableBytes {
            _ = state.fillFrames(into: $0.baseAddress!.assumingMemoryBound(to: UInt8.self), capacity: $0.count)
        }
        #expect(output == [2, 3])
        #expect(state.dropCounter == 1_232)
        #expect(state.cursorMicroseconds == 1_000_068)
        #expect(state.cursorRemainder == 1_200)
        enqueue([4, 5], at: 1_000_068, into: &state)
        output.withUnsafeMutableBytes {
            _ = state.fillFrames(into: $0.baseAddress!.assumingMemoryBound(to: UInt8.self), capacity: $0.count)
        }
        #expect(output == [4, 5])
        #expect(state.dropCounter == 1_230)
        #expect(state.correctionSchedule == schedule)
        #expect(state.flowDiagnostics.reanchors == reanchors)
    }

    @Test func fractionalTrimPreservesNextSampleIdentity() {
        var state = state(rate: 44_100)
        defer { state.deallocateResources() }
        enqueue([1, 2, 3, 4, 5], at: 1_000_000, into: &state)
        state.trimStalePCM(at: 1_000_024)
        #expect(state.framesConsumed == 2)
        #expect(state.cursorMicroseconds == 1_000_045)
        #expect(state.cursorRemainder == 15_500)
        state.trimStalePCM(at: 1_000_045)
        #expect(state.framesConsumed == 2)
        #expect(render(&state, now: 1_000_046, frames: 3, depth: 0) == [3, 4, 5])
    }
}
