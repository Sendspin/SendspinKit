import Foundation
@testable import SendspinKit
import Testing

struct AudioPlayerTests {
    @Test
    func `Initialize AudioPlayer with dependencies`() async {
        let player = AudioPlayer()

        let isPlaying = await player.isPlaying
        #expect(isPlaying == false)
    }

    @Test
    func `Configure audio format`() async throws {
        let player = AudioPlayer()

        let format = try AudioFormatSpec(
            codec: .pcm,
            channels: 2,
            sampleRate: 48_000,
            bitDepth: 16
        )

        try await player.start(format: format, codecHeader: nil)

        let isPlaying = await player.isPlaying
        #expect(isPlaying == true)
    }

    @Test
    func `Play PCM data with timestamp`() async throws {
        let player = AudioPlayer()

        let format = try AudioFormatSpec(
            codec: .pcm,
            channels: 2,
            sampleRate: 48_000,
            bitDepth: 16
        )

        try await player.start(format: format, codecHeader: nil)

        // Create 1 second of silence
        let bytesPerSample = format.channels * format.bitDepth / 8
        let samplesPerSecond = format.sampleRate
        let pcmData = Data(repeating: 0, count: samplesPerSecond * bytesPerSample)

        // Should not throw — timestamp 0 is fine for tests
        try await player.playPCM(pcmData, serverTimestamp: 0)

        await player.stop()
    }

    @Test
    func `Verify old enqueue method removed`() async throws {
        // This test documents that the old enqueue(chunk:) method has been removed
        // in favor of the AudioScheduler-based architecture.
        // The new flow is: SendspinClient -> AudioScheduler -> AudioPlayer.playPCM(_:serverTimestamp:)

        let player = AudioPlayer()

        let format = try AudioFormatSpec(codec: .pcm, channels: 2, sampleRate: 48_000, bitDepth: 16)
        try await player.start(format: format, codecHeader: nil)

        let pcmData = Data(repeating: 0, count: 1_024)
        try await player.playPCM(pcmData, serverTimestamp: 0)

        await player.stop()
    }

    // MARK: - Perceptual volume

    @Test
    func `Perceptual gain at boundaries`() {
        #expect(AudioPlayer.perceptualGain(0.0) == 0.0)
        #expect(AudioPlayer.perceptualGain(1.0) == 1.0)
    }

    @Test
    func `Perceptual gain is non-linear`() {
        let halfLinear = AudioPlayer.perceptualGain(0.5)
        // (0.5)^1.5 ≈ 0.354 — quieter than linear 0.5
        #expect(halfLinear < 0.5)
        #expect(halfLinear > 0.0)
        // Should be close to 0.354
        #expect(abs(halfLinear - 0.354) < 0.01)
    }

    @Test
    func `Perceptual gain is monotonically increasing`() {
        var previous: Float = -1.0
        for i in 0 ... 100 {
            let gain = AudioPlayer.perceptualGain(Float(i) / 100.0)
            #expect(gain >= previous, "Gain should increase: \(i)% gave \(gain), previous was \(previous)")
            previous = gain
        }
    }

    @Test
    func `Decode method still available`() async throws {
        let player = AudioPlayer()

        let format = try AudioFormatSpec(codec: .pcm, channels: 2, sampleRate: 48_000, bitDepth: 16)
        try await player.start(format: format, codecHeader: nil)

        // Decode should work for PCM passthrough
        let inputData = Data(repeating: 0, count: 1_024)
        let decoded = try await player.decode(inputData)

        #expect(decoded.count == 1_024) // PCM passthrough should return same size

        await player.stop()
    }
}
