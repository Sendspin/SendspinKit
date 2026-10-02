@testable import SendspinKit
import Testing

struct CallbackDepthTelemetryTests {
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
