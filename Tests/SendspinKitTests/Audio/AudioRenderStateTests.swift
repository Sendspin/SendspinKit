import Foundation
@testable import SendspinKit
import Testing

struct AudioRenderStateTests {
    private let sampleRate = 48_000
    private let frameSize = MemoryLayout<Int16>.size
    private let startCursor: Int64 = 1_000_000

    @Test func normalFramesPreserveOrderAndFractionalCursor() {
        var state = makeState(samples: [1, 2, 3, 4, 5])
        defer { state.deallocateResources() }

        #expect(render(&state, frames: 3) == [1, 2, 3])
        #expect(render(&state, frames: 2) == [4, 5])
        expectCursor(state, consumed: 5)
        #expect(state.pcmRingBuffer.availableToRead == 0)
        #expect(state.underrunCount == 0)
    }

    @Test func dropsConsumeSamplesAndAdvanceCursor() {
        var state = makeState(samples: [1, 2, 3, 4, 5, 6])
        defer { state.deallocateResources() }
        state.correctionSchedule = CorrectionSchedule(dropEveryNFrames: 2)
        state.dropCounter = 2

        #expect(render(&state, frames: 4) == [1, 3, 4, 6])
        expectCursor(state, consumed: 6)
        #expect(state.flowDiagnostics.correctionDrops == 2)
        #expect(state.pcmRingBuffer.availableToRead == 0)
    }

    @Test func insertsRepeatLastSampleAcrossCallbacksWithoutAdvancingCursor() {
        var state = makeState(samples: [1, 2, 3])
        defer { state.deallocateResources() }
        state.correctionSchedule = CorrectionSchedule(insertEveryNFrames: 2)
        state.insertCounter = 2

        #expect(render(&state, frames: 3) == [1, 1, 2])
        #expect(render(&state, frames: 3) == [2, 3, 3])
        expectCursor(state, consumed: 3)
        #expect(state.pcmRingBuffer.availableToRead == 0)
        #expect(state.underrunCount == 0)
    }

    @Test func underrunReturnsOnlyWrittenFramesAndDoesNotAdvanceThroughMissingAudio() {
        var state = makeState(samples: [1, 2])
        defer { state.deallocateResources() }

        #expect(render(&state, frames: 4) == [1, 2])
        expectCursor(state, consumed: 2)
        #expect(state.underrunCount == 1)
        #expect(state.flowDiagnostics.missingFrames == 2)
        write([3, 4], to: &state)
        #expect(render(&state, frames: 2) == [3, 4])
        expectCursor(state, consumed: 4)
    }

    @Test func alignedGraceExpiryKeepsSampleIdentityAndCursorAligned() {
        var state = makeState(samples: [1, 2, 3, 4])
        defer { state.deallocateResources() }
        state.timeSnapshot = TimeFilterSnapshot(
            offset: 0, drift: 0, lastUpdate: 0, useDrift: false, clientProcessStartAbsolute: 0
        )
        state.correctionGraceFrames = 4
        state.updateCorrectionSchedule(
            localNow: startCursor, capacity: 4 * frameSize, frameSize: frameSize,
            sampleRate: sampleRate, inFlightAtCallback: 0
        )

        #expect(render(&state, frames: 4) == [1, 2, 3, 4])
        expectCursor(state, consumed: 4)
        #expect(state.correctionGraceFrames == 0)
        #expect(state.startupOffsetUs == 0)
        #expect(!state.correctionSchedule.isCorrecting)
    }

    @Test(arguments: [Int64(-120_000), Int64(120_000)])
    func graceExpiryPreservesNextSourceTimestamp(mismatchUs: Int64) {
        var state = makeState(samples: [101, 102, 103, 104, 105, 106])
        defer { state.deallocateResources() }
        #expect(render(&state, frames: 1) == [101])
        expectCursor(state, consumed: 1)
        let sourceCursor = state.cursorMicroseconds
        let sourceRemainder = state.cursorRemainder
        state.timeSnapshot = TimeFilterSnapshot(
            offset: 0, drift: 0, lastUpdate: 0, useDrift: false, clientProcessStartAbsolute: 0
        )
        state.correctionGraceFrames = 4
        state.correctionSchedule = CorrectionSchedule(dropEveryNFrames: 2)
        state.dropCounter = 1
        state.insertCounter = 1
        state.updateCorrectionSchedule(
            localNow: sourceCursor + mismatchUs, capacity: 4 * frameSize, frameSize: frameSize,
            sampleRate: sampleRate, inFlightAtCallback: 0
        )

        #expect(state.startupOffsetUs == mismatchUs)
        #expect(state.lastSyncErrorUs == mismatchUs)
        #expect(state.cursorMicroseconds == sourceCursor)
        #expect(state.cursorRemainder == sourceRemainder)
        #expect(!state.correctionSchedule.isCorrecting)
        #expect(state.dropCounter == 0)
        #expect(state.insertCounter == 0)
        #expect(render(&state, frames: 4) == [102, 103, 104, 105])
        expectCursor(state, consumed: 5)
        #expect(render(&state, frames: 1) == [106])
        expectCursor(state, consumed: 6)
    }

    private func makeState(samples: [Int16]) -> AudioRenderState {
        var state = AudioRenderState(pcmRingBuffer: PCMRingBuffer(capacity: 64))
        state.frameSize = frameSize
        state.sampleRate = sampleRate
        state.cursorMicroseconds = startCursor
        state.prewarming = false
        write(samples, to: &state)
        return state
    }

    private func write(_ samples: [Int16], to state: inout AudioRenderState) {
        samples.withUnsafeBytes { bytes in
            #expect(state.pcmRingBuffer.write(from: bytes.baseAddress!, count: bytes.count) == bytes.count)
        }
    }

    private func render(_ state: inout AudioRenderState, frames: Int) -> [Int16] {
        var output = [Int16](repeating: -1, count: frames)
        let written = output.withUnsafeMutableBytes { bytes in
            state.fillFrames(into: bytes.baseAddress!.assumingMemoryBound(to: UInt8.self), capacity: bytes.count)
        }
        #expect(output.dropFirst(written / frameSize).allSatisfy { $0 == -1 })
        return Array(output.prefix(written / frameSize))
    }

    private func expectCursor(_ state: borrowing AudioRenderState, consumed: Int64) {
        #expect(state.framesConsumed == consumed)
        #expect(state.cursorMicroseconds == startCursor + consumed * 1_000_000 / Int64(sampleRate))
        #expect(state.cursorRemainder == consumed * 1_000_000 % Int64(sampleRate))
    }
}
