import Foundation
@testable import SendspinKit
import Testing

enum RealAudioTestGate {
    static var enabled: Bool {
        ProcessInfo.processInfo.environment["SENDSPIN_REAL_AUDIO_TESTS"] == "1"
    }

    static let reason: Comment = "Set SENDSPIN_REAL_AUDIO_TESTS=1 to run real AudioQueue hardware tests"
}

struct AudioPlayerTests {
    @Test
    func initializeAudioPlayerWithDependencies() async {
        let player = AudioPlayer()

        let isPlaying = await player.isPlaying
        #expect(isPlaying == false)
    }

    @Test(.enabled(if: RealAudioTestGate.enabled, RealAudioTestGate.reason))
    func configureAudioFormat() async throws {
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

    @Test(.enabled(if: RealAudioTestGate.enabled, RealAudioTestGate.reason))
    func playPCMDataWithTimestamp() async throws {
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

    @Test(.enabled(if: RealAudioTestGate.enabled, RealAudioTestGate.reason))
    func verifyOldEnqueueMethodRemoved() async throws {
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

    @Test(.enabled(if: RealAudioTestGate.enabled, RealAudioTestGate.reason))
    func sameFormatPrepareWhilePlayingRebuildsForPreparedRestart() async throws {
        let player = AudioPlayer()
        let format = try AudioFormatSpec(codec: .pcm, channels: 2, sampleRate: 48_000, bitDepth: 16)

        try await player.start(format: format, codecHeader: nil)
        #expect(await player.isPlaying)

        try await player.prepare(format: format, codecHeader: nil)
        #expect(await !(player.isPlaying), "prepare must stop a live same-format queue before a prepared restart")

        let frameBytes = format.channels * format.effectiveOutputBitDepth / 8
        try await player.playPCM(Data(repeating: 0, count: format.sampleRate * frameBytes / 10), serverTimestamp: 123_000)
        await player.alignPreparedStartCursor(firstServerTimestamp: 123_000)
        try await player.startPrepared()
        #expect(await player.isPlaying)

        await player.stop()
    }

    // MARK: - PCM decoding

    @Test
    func pcmDecoder16BitPassesThroughLittleEndianSamples() throws {
        let decoder = PCMDecoder(bitDepth: 16, channels: 1)
        let input = Data([0x34, 0x12, 0xCD, 0xAB])

        let decoded = try decoder.decode(input)

        #expect(decoded == input, "16-bit PCM wire bytes are already little-endian signed samples")
    }

    @Test
    func pcmDecoder24BitUnpacksLittleEndianSamplesIntoLeftJustifiedInt32() throws {
        let decoder = PCMDecoder(bitDepth: 24, channels: 1)
        let input = Data([
            0x56, 0x34, 0x12, // 0x123456 -> 0x12345600
            0xFF, 0xFF, 0x7F // max positive -> 0x7FFFFF00
        ])

        let decoded = try decoder.decode(input)

        #expect(Array(decoded) == [
            0x00, 0x56, 0x34, 0x12,
            0x00, 0xFF, 0xFF, 0x7F
        ])
    }

    @Test
    func pcmDecoder24BitSignExtendsNegativeSamples() throws {
        let decoder = PCMDecoder(bitDepth: 24, channels: 1)
        let input = Data([
            0x00, 0x00, 0x80, // min negative -> 0x80000000 after left shift
            0xFF, 0xFF, 0xFF // -1 -> 0xFFFFFF00 after left shift
        ])

        let decoded = try decoder.decode(input)

        #expect(Array(decoded) == [
            0x00, 0x00, 0x00, 0x80,
            0x00, 0xFF, 0xFF, 0xFF
        ])
    }

    @Test
    func pcmDecoderReturnsEmptyForEmptyInputAtEveryWidth() throws {
        // The empty→empty invariant is uniform across PCM widths. The 24-bit case is
        // load-bearing: without the front-door guard it would trap in withUnsafeBytes
        // (baseAddress is nil for empty Data).
        for bitDepth in [16, 24, 32] {
            let decoder = PCMDecoder(bitDepth: bitDepth, channels: 1)
            let decoded = try decoder.decode(Data())
            #expect(decoded.isEmpty, "bitDepth \(bitDepth): empty input must decode to empty output")
        }
    }

    // MARK: - Perceptual volume

    @Test
    func graceExpiryRebaselineCursorAbsorbsStartupBias() {
        let formatSampleRate = 44_100
        let formatChannels = 2
        let formatBytesPerSample = MemoryLayout<Int16>.size
        let bytesPerFrame = formatChannels * formatBytesPerSample
        let expectedServerTime: Int64 = 10_000_000
        let audioQueueLatencyUs = Int64(audioQueueEstimatedInFlightBuffers) * Int64(audioQueueBufferByteSize) * 1_000_000
            / Int64(formatSampleRate * bytesPerFrame)
        let biasedRawCursor = expectedServerTime

        let biasedSyncError = (expectedServerTime - biasedRawCursor) - audioQueueLatencyUs
        #expect(biasedSyncError < -CorrectionPlanner.defaultEngageUs)
        #expect(CorrectionPlanner().plan(
            errorMicroseconds: biasedSyncError,
            sampleRate: UInt32(formatSampleRate),
            currentlyCorrecting: false
        ).insertEveryNFrames > 0)

        let rebaselinedCursor = AudioPlayer.graceExpiryRebaselineCursor(
            expectedServerTime: expectedServerTime,
            audioQueueLatencyUs: audioQueueLatencyUs
        )
        #expect(rebaselinedCursor == expectedServerTime - audioQueueLatencyUs)

        let rebaselinedSyncError = (expectedServerTime - rebaselinedCursor) - audioQueueLatencyUs
        #expect(CorrectionPlanner().plan(
            errorMicroseconds: rebaselinedSyncError,
            sampleRate: UInt32(formatSampleRate),
            currentlyCorrecting: false
        ) == CorrectionSchedule())
    }

    @Test
    func perceptualGainAtBoundaries() {
        #expect(AudioPlayer.perceptualGain(0.0) == 0.0)
        #expect(AudioPlayer.perceptualGain(1.0) == 1.0)
    }

    @Test
    func perceptualGainIsNonLinear() {
        let halfLinear = AudioPlayer.perceptualGain(0.5)
        // (0.5)^1.5 ≈ 0.354 — quieter than linear 0.5
        #expect(halfLinear < 0.5)
        #expect(halfLinear > 0.0)
        // Should be close to 0.354
        #expect(abs(halfLinear - 0.354) < 0.01)
    }

    @Test
    func perceptualGainIsMonotonicallyIncreasing() {
        var previous: Float = -1.0
        for i in 0 ... 100 {
            let gain = AudioPlayer.perceptualGain(Float(i) / 100.0)
            #expect(gain >= previous, "Gain should increase: \(i)% gave \(gain), previous was \(previous)")
            previous = gain
        }
    }

    @Test(.enabled(if: RealAudioTestGate.enabled, RealAudioTestGate.reason))
    func decodeMethodStillAvailable() async throws {
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
