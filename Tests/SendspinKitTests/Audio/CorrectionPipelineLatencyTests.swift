@testable import SendspinKit
import Testing

struct CorrectionPipelineLatencyTests {
    @Test func measuredDepthIncludesDeviceLatency() throws {
        let format = try AudioFormatSpec(codec: .pcm, channels: 2, sampleRate: 48_000, bitDepth: 16)
        let frames = Int64(format.sampleRate / format.channels)
        let deviceLatency = Int64(1_000_000 / format.sampleRate)
        let modelledDepth = Int64(audioQueueBufferCount) * Int64(audioQueueBufferByteSize) * 1_000_000
            / Int64(format.sampleRate * format.channels * (format.bitDepth / 8))
        let pipeline = AudioPlayer.correctionPipelineLatencyUs(
            inFlightFrames: frames, sampleRate: format.sampleRate,
            modelledQueueDepthUs: modelledDepth, deviceLatencyUs: deviceLatency
        )
        #expect(pipeline == 1_000_000 / Int64(format.channels) + deviceLatency)
        #expect(pipeline != modelledDepth + deviceLatency)
    }

    @Test func missedPositionHoldsDepthAndUnobservedPositionUsesModel() throws {
        let format = try AudioFormatSpec(codec: .pcm, channels: 2, sampleRate: 48_000, bitDepth: 16)
        let frames = Int64(format.sampleRate / format.channels)
        let deviceLatency = Int64(1_000_000 / format.sampleRate)
        let modelledDepth = Int64(audioQueueBufferCount) * Int64(audioQueueBufferByteSize) * 1_000_000
            / Int64(format.sampleRate * format.channels * (format.bitDepth / 8))
        var previous: Int64?
        let absent = CallbackDepthTelemetry.measuredDepth(total: frames, played: 0, previous: &previous)
        #expect(absent == nil)
        #expect(AudioPlayer.correctionPipelineLatencyUs(
            inFlightFrames: absent, sampleRate: format.sampleRate,
            modelledQueueDepthUs: modelledDepth, deviceLatencyUs: deviceLatency
        ) == modelledDepth + deviceLatency)
        let observed = CallbackDepthTelemetry.measuredDepth(total: frames + frames, played: frames, previous: &previous)
        #expect(observed == frames)
        let missed = CallbackDepthTelemetry.measuredDepth(total: frames + frames + frames, played: 0, previous: &previous)
        #expect(missed == frames)
        #expect(AudioPlayer.correctionPipelineLatencyUs(
            inFlightFrames: missed, sampleRate: format.sampleRate,
            modelledQueueDepthUs: modelledDepth, deviceLatencyUs: deviceLatency
        ) == 1_000_000 / Int64(format.channels) + deviceLatency)
    }
}
