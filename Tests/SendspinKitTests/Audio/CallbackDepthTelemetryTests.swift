@testable import SendspinKit
import Testing

struct CallbackDepthTelemetryTests {
    @Test func skipsDoNotChangeDepthAndMissedPositionKeepsLatch() throws {
        let format = try AudioFormatSpec(codec: .pcm, channels: 2, sampleRate: 48_000, bitDepth: 16)
        let buffer = Int64(audioQueueBufferByteSize) / Int64(format.channels * (format.bitDepth / 8))
        let total = buffer * Int64(audioQueueBufferCount)
        var telemetry = CallbackDepthTelemetry()
        telemetry.record(total: total, played: buffer, bufferFrames: buffer, costUs: buffer, prewarming: true)
        telemetry.record(total: total, played: 0, bufferFrames: buffer, costUs: 0, prewarming: false)
        #expect(telemetry.prewarmSkipped == 1)
        #expect(telemetry.zeroPlayedSkipped == 1)
        #expect(telemetry.samples == 0)
        #expect(telemetry.minimum == 0 && telemetry.maximum == 0 && telemetry.last == 0)
        var previous: Int64?
        let measured = CallbackDepthTelemetry.measuredDepth(total: total, played: buffer, previous: &previous)
        telemetry.record(total: total, played: buffer, bufferFrames: buffer, costUs: 0, prewarming: false)
        telemetry.record(total: total, played: 0, bufferFrames: buffer, costUs: 0, prewarming: false)
        #expect(CallbackDepthTelemetry.measuredDepth(total: total + buffer, played: 0, previous: &previous) == measured)
        #expect(telemetry.zeroPlayedSkipped == 2)
        #expect(telemetry.samples == 1)
        #expect(telemetry.last == total - buffer)
        #expect(telemetry.timeCostUs == buffer)
    }

    @Test func aggregatesMinimumMaximumLastDelayAndCost() {
        let buffer = Int64(audioQueueBufferByteSize)
        let total = buffer * Int64(audioQueueBufferCount)
        var telemetry = CallbackDepthTelemetry()
        telemetry.record(total: total, played: buffer, bufferFrames: buffer, costUs: buffer, prewarming: false)
        telemetry.record(total: total, played: buffer + buffer, bufferFrames: buffer, costUs: 0, prewarming: false)
        telemetry.record(total: total, played: 1, bufferFrames: buffer, costUs: buffer + buffer, prewarming: false)
        #expect(telemetry.minimum == total - buffer - buffer)
        #expect(telemetry.maximum == total - 1)
        #expect(telemetry.last == total - 1)
        #expect(telemetry.delayFrames == buffer)
        #expect(telemetry.timeCostUs == buffer + buffer)
        #expect(telemetry.samples == Int64(audioQueueBufferCount))
        #expect(telemetry.prewarmSkipped == 0 && telemetry.zeroPlayedSkipped == 0)
    }

    @Test func depthClampsAndMeasuresDeliveryDelay() {
        let bufferFrames = Int64(audioQueueBufferByteSize)
        let modelled = Int64(audioQueueBufferCount) * bufferFrames
        let afterCompletion = modelled - bufferFrames
        let delivered = CallbackDepthTelemetry.depth(
            total: modelled, played: bufferFrames + bufferFrames, bufferFrames: bufferFrames
        )
        #expect(delivered.inFlight == afterCompletion - bufferFrames)
        #expect(delivered.delay == bufferFrames)
        let ahead = CallbackDepthTelemetry.depth(total: modelled, played: 0, bufferFrames: bufferFrames)
        #expect(ahead.inFlight == modelled)
        #expect(ahead.delay == 0)
        let exhausted = CallbackDepthTelemetry.depth(total: bufferFrames, played: modelled, bufferFrames: bufferFrames)
        #expect(exhausted.inFlight == 0)
        #expect(exhausted.delay == afterCompletion)
    }
}
