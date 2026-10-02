@testable import SendspinKit
import Testing

struct CorrectionPipelineLatencyTests {
    @Test func measuredDepthIncludesDeviceLatency() {
        let rate = Int(audioQueueBufferByteSize)
        let frames = Int64(audioQueueBufferByteSize)
        let deviceLatency = Int64(audioQueueBufferCount)
        let modelledDepth = frames * Int64(audioQueueBufferCount)
        let pipeline = AudioPlayer.correctionPipelineLatencyUs(
            inFlightFrames: frames, sampleRate: rate,
            modelledQueueDepthUs: modelledDepth, deviceLatencyUs: deviceLatency
        )
        #expect(pipeline == frames * 1_000_000 / Int64(rate) + deviceLatency)
        #expect(pipeline != modelledDepth + deviceLatency)
    }

    @Test func unavailableDepthIncludesDeviceLatencyWithModel() {
        let rate = Int(audioQueueBufferByteSize)
        let modelledDepth = Int64(audioQueueBufferByteSize) * Int64(audioQueueBufferCount)
        let deviceLatency = Int64(audioQueueBufferCount)
        let pipeline = AudioPlayer.correctionPipelineLatencyUs(
            inFlightFrames: nil, sampleRate: rate,
            modelledQueueDepthUs: modelledDepth, deviceLatencyUs: deviceLatency
        )
        #expect(pipeline == modelledDepth + deviceLatency)
        #expect(pipeline != deviceLatency)
    }
}
