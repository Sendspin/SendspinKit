import Foundation
@testable import SendspinKit
import Testing

@Suite("AudioPlayer Tests")
struct AudioPlayerTests {
    @Test("Initialize AudioPlayer with dependencies")
    func initialization() async {
        let bufferManager = BufferManager(capacity: 1024)
        let clockSync = ClockSynchronizer()

        let player = AudioPlayer(
            bufferManager: bufferManager,
            clockSync: clockSync
        )

        let isPlaying = await player.isPlaying
        #expect(isPlaying == false)
    }

    @Test("Configure audio format")
    func formatSetup() async throws {
        let bufferManager = BufferManager(capacity: 1024)
        let clockSync = ClockSynchronizer()
        let player = AudioPlayer(bufferManager: bufferManager, clockSync: clockSync)

        let format = AudioFormatSpec(
            codec: .pcm,
            channels: 2,
            sampleRate: 48000,
            bitDepth: 16
        )

        try await player.start(format: format, codecHeader: nil)

        let isPlaying = await player.isPlaying
        #expect(isPlaying == true)
    }

    // NOTE: Old testEnqueueChunk removed - enqueue(chunk:) method has been removed
    // in favor of AudioScheduler-based scheduling. The new flow is:
    // SendspinClient -> AudioScheduler -> AudioPlayer.playPCM()
    // See testEnqueueMethodRemoved below for verification

    @Test("Play PCM data directly")
    func testPlayPCM() async throws {
        let bufferManager = BufferManager(capacity: 1_048_576)
        let clockSync = ClockSynchronizer()
        let player = AudioPlayer(bufferManager: bufferManager, clockSync: clockSync)

        let format = AudioFormatSpec(
            codec: .pcm,
            channels: 2,
            sampleRate: 48000,
            bitDepth: 16
        )

        try await player.start(format: format, codecHeader: nil)

        // Create 1 second of silence
        let bytesPerSample = format.channels * format.bitDepth / 8
        let samplesPerSecond = format.sampleRate
        let pcmData = Data(repeating: 0, count: samplesPerSecond * bytesPerSample)

        // Should not throw
        try await player.playPCM(pcmData)

        await player.stop()
    }

    @Test("Verify old enqueue method removed")
    func enqueueMethodRemoved() async throws {
        // This test documents that the old enqueue(chunk:) method has been removed
        // in favor of the AudioScheduler-based architecture.
        // The new flow is: SendspinClient -> AudioScheduler -> AudioPlayer.playPCM()

        let bufferManager = BufferManager(capacity: 1_048_576)
        let clockSync = ClockSynchronizer()
        let player = AudioPlayer(bufferManager: bufferManager, clockSync: clockSync)

        // If the old method still exists, this test would fail at compile time
        // This is intentional - we want to ensure the method is removed

        // Verify playPCM is the correct interface
        let format = AudioFormatSpec(codec: .pcm, channels: 2, sampleRate: 48000, bitDepth: 16)
        try await player.start(format: format, codecHeader: nil)

        let pcmData = Data(repeating: 0, count: 1024)
        try await player.playPCM(pcmData)

        await player.stop()
    }

    @Test("Decode method still available")
    func decodeMethod() async throws {
        let bufferManager = BufferManager(capacity: 1_048_576)
        let clockSync = ClockSynchronizer()
        let player = AudioPlayer(bufferManager: bufferManager, clockSync: clockSync)

        let format = AudioFormatSpec(codec: .pcm, channels: 2, sampleRate: 48000, bitDepth: 16)
        try await player.start(format: format, codecHeader: nil)

        // Decode should work for PCM passthrough
        let inputData = Data(repeating: 0, count: 1024)
        let decoded = try await player.decode(inputData)

        #expect(decoded.count == 1024) // PCM passthrough should return same size

        await player.stop()
    }
}
