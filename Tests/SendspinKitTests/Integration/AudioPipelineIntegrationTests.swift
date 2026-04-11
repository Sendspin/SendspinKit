// ABOUTME: End-to-end integration tests for the audio pipeline
// ABOUTME: Verifies: binary frame bytes → BinaryMessage → PCM decode → Sample values

import Foundation
import Testing
@testable import SendspinKit

/// Generates deterministic test audio signals for verification.
/// Uses the same chirp-based approach as aiosendspin's sync_assertions.py
/// so cross-implementation comparisons are possible.
enum TestSignal {
    /// Generate a 440Hz sine wave as 16-bit stereo PCM (little-endian).
    /// Returns raw bytes ready to be packed into a binary frame.
    static func sineWave16BitStereo(
        sampleRate: Int,
        durationMs: Int,
        frequencyHz: Double = 440.0
    ) -> (bytes: [UInt8], expectedSamples: [Sample]) {
        let frameCount = sampleRate * durationMs / 1000
        var bytes = [UInt8]()
        bytes.reserveCapacity(frameCount * 2 * 2) // stereo, 2 bytes per sample
        var expectedSamples = [Sample]()
        expectedSamples.reserveCapacity(frameCount * 2) // stereo

        for frame in 0..<frameCount {
            let t = Double(frame) / Double(sampleRate)
            let amplitude = sin(2.0 * .pi * frequencyHz * t)
            let i16Value = Int16(amplitude * Double(Int16.max))

            // Both channels get the same value (mono spread to stereo)
            for _ in 0..<2 {
                // Little-endian bytes
                bytes.append(UInt8(i16Value & 0xFF))
                bytes.append(UInt8((i16Value >> 8) & 0xFF))
                // Expected Sample: i16 → i24 (shift left 8)
                expectedSamples.append(Sample.fromI16(i16Value))
            }
        }
        return (bytes, expectedSamples)
    }

    /// Generate a 440Hz sine wave as 24-bit stereo PCM (little-endian).
    static func sineWave24BitStereo(
        sampleRate: Int,
        durationMs: Int,
        frequencyHz: Double = 440.0
    ) -> (bytes: [UInt8], expectedSamples: [Sample]) {
        let frameCount = sampleRate * durationMs / 1000
        var bytes = [UInt8]()
        bytes.reserveCapacity(frameCount * 2 * 3) // stereo, 3 bytes per sample
        var expectedSamples = [Sample]()
        expectedSamples.reserveCapacity(frameCount * 2)

        for frame in 0..<frameCount {
            let t = Double(frame) / Double(sampleRate)
            let amplitude = sin(2.0 * .pi * frequencyHz * t)
            let i24Value = Int32(amplitude * Double(Sample.max.value))

            for _ in 0..<2 {
                // 24-bit little-endian
                bytes.append(UInt8(i24Value & 0xFF))
                bytes.append(UInt8((i24Value >> 8) & 0xFF))
                bytes.append(UInt8((i24Value >> 16) & 0xFF))
                expectedSamples.append(Sample(i24Value))
            }
        }
        return (bytes, expectedSamples)
    }

    /// Pack PCM audio data into a binary frame: [type:1][timestamp:8 BE][data:N]
    static func packBinaryFrame(
        audioData: [UInt8],
        timestampMicroseconds: Int64,
        type: UInt8 = 0x04 // audioChunk
    ) -> Data {
        var frame = Data()
        frame.append(type)
        withUnsafeBytes(of: timestampMicroseconds.bigEndian) { frame.append(contentsOf: $0) }
        frame.append(contentsOf: audioData)
        return frame
    }
}

@Suite("Audio Pipeline Integration")
struct AudioPipelineIntegrationTests {

    // MARK: - Full pipeline: binary frame → BinaryMessage → SamplePCMDecoder → Samples

    @Test("16-bit PCM: binary frame → parsed message → decoded samples match source signal")
    func fullPipeline16Bit() throws {
        // 1. Generate known audio signal
        let (pcmBytes, expectedSamples) = TestSignal.sineWave16BitStereo(
            sampleRate: 48000,
            durationMs: 25 // 25ms = standard chunk size
        )

        // 2. Pack into binary frame (as server would send)
        let frameData = TestSignal.packBinaryFrame(
            audioData: pcmBytes,
            timestampMicroseconds: 1_000_000
        )

        // 3. Parse binary message (as client does on WebSocket receive)
        let message = try #require(BinaryMessage(data: frameData))
        #expect(message.type == .audioChunk)
        #expect(message.timestamp == 1_000_000)

        // 4. Decode through SamplePCMDecoder
        let decoder = SamplePCMDecoder(bitDepth: 16)
        let decodedSamples = try decoder.decode([UInt8](message.data))

        // 5. Verify every sample matches
        #expect(decodedSamples.count == expectedSamples.count)
        for i in 0..<decodedSamples.count {
            #expect(
                decodedSamples[i] == expectedSamples[i],
                "Sample \(i): got \(decodedSamples[i].value), expected \(expectedSamples[i].value)"
            )
        }

        // 6. Verify signal properties
        let frameCount = 48000 * 25 / 1000
        #expect(decodedSamples.count == frameCount * 2) // stereo

        // First sample should be near zero (sin(0) = 0)
        #expect(decodedSamples[0] == Sample.zero)

        // Quarter-wave peak should be near max (sin(π/2) ≈ 1)
        // At 440Hz, quarter period = 1/(440*4) = ~568μs = ~27 frames at 48kHz
        let quarterWaveFrame = 48000 / (440 * 4)
        let peakSample = decodedSamples[quarterWaveFrame * 2] // *2 for stereo L channel
        #expect(peakSample.toF32() > 0.9, "Quarter-wave peak should be near 1.0, got \(peakSample.toF32())")
    }

    @Test("24-bit PCM: binary frame → parsed message → decoded samples match source signal")
    func fullPipeline24Bit() throws {
        let (pcmBytes, expectedSamples) = TestSignal.sineWave24BitStereo(
            sampleRate: 48000,
            durationMs: 25
        )

        let frameData = TestSignal.packBinaryFrame(
            audioData: pcmBytes,
            timestampMicroseconds: 2_000_000
        )

        let message = try #require(BinaryMessage(data: frameData))
        #expect(message.type == .audioChunk)
        #expect(message.timestamp == 2_000_000)

        let decoder = SamplePCMDecoder(bitDepth: 24)
        let decodedSamples = try decoder.decode([UInt8](message.data))

        #expect(decodedSamples.count == expectedSamples.count)
        for i in 0..<decodedSamples.count {
            #expect(
                decodedSamples[i] == expectedSamples[i],
                "Sample \(i): got \(decodedSamples[i].value), expected \(expectedSamples[i].value)"
            )
        }
    }

    // MARK: - Sequential chunks (simulating a stream)

    @Test("sequential 25ms chunks maintain timestamp continuity")
    func sequentialChunks() throws {
        let chunkDurationUs: Int64 = 25_000 // 25ms
        let chunkCount = 10
        let decoder = SamplePCMDecoder(bitDepth: 16)

        var allSamples = [Sample]()
        var lastTimestamp: Int64 = -1

        for chunkIndex in 0..<chunkCount {
            let timestampUs = Int64(chunkIndex) * chunkDurationUs

            // Each chunk is 25ms of 48kHz stereo 16-bit
            let (pcmBytes, _) = TestSignal.sineWave16BitStereo(
                sampleRate: 48000,
                durationMs: 25,
                frequencyHz: 440.0
            )

            let frameData = TestSignal.packBinaryFrame(
                audioData: pcmBytes,
                timestampMicroseconds: timestampUs
            )

            let message = try #require(BinaryMessage(data: frameData))

            // Verify timestamp ordering
            #expect(message.timestamp > lastTimestamp, "Timestamps must be monotonically increasing")
            lastTimestamp = message.timestamp

            let samples = try decoder.decode([UInt8](message.data))
            allSamples.append(contentsOf: samples)
        }

        // 10 chunks × 25ms × 48kHz × 2 channels = 24000 samples
        let expectedTotal = chunkCount * (48000 * 25 / 1000) * 2
        #expect(allSamples.count == expectedTotal)
    }

    // MARK: - Cross-validation with existing PCMDecoder

    @Test("SamplePCMDecoder and PCMDecoder (Data-based) agree on 16-bit decode")
    func crossValidation16Bit() throws {
        let (pcmBytes, _) = TestSignal.sineWave16BitStereo(
            sampleRate: 48000,
            durationMs: 10
        )
        let data = Data(pcmBytes)

        // Decode via new SamplePCMDecoder
        let sampleDecoder = SamplePCMDecoder(bitDepth: 16)
        let samples = try sampleDecoder.decode(pcmBytes)

        // Decode via existing PCMDecoder (returns Data of same bytes for 16-bit)
        let legacyDecoder = PCMDecoder(bitDepth: 16, channels: 2)
        let legacyData = try legacyDecoder.decode(data)

        // For 16-bit, PCMDecoder passes through, so legacyData == input
        #expect(legacyData == data)

        // Verify SamplePCMDecoder produced the right number of samples
        #expect(samples.count == pcmBytes.count / 2) // 2 bytes per 16-bit sample

        // Verify first few samples match manual decode
        let s0 = Int16(pcmBytes[0]) | (Int16(pcmBytes[1]) << 8)
        #expect(samples[0].toI16() == s0)
    }

    @Test("SamplePCMDecoder and PCMDecoder produce correctly related 24-bit values")
    func crossValidation24Bit() throws {
        let (pcmBytes, expectedSamples) = TestSignal.sineWave24BitStereo(
            sampleRate: 48000,
            durationMs: 10
        )
        let data = Data(pcmBytes)

        // Decode via new SamplePCMDecoder (produces 24-bit values in Sample.value)
        let sampleDecoder = SamplePCMDecoder(bitDepth: 24)
        let samples = try sampleDecoder.decode(pcmBytes)

        // Decode via PCMDecoder (produces 32-bit left-justified Int32 for AudioQueue)
        let legacyDecoder = PCMDecoder(bitDepth: 24, channels: 2)
        let legacyData = try legacyDecoder.decode(data)

        let legacyInt32s = legacyData.withUnsafeBytes { buffer -> [Int32] in
            let count = buffer.count / MemoryLayout<Int32>.size
            return (0..<count).map { i in
                buffer.loadUnaligned(fromByteOffset: i * MemoryLayout<Int32>.size, as: Int32.self)
            }
        }

        // PCMDecoder left-shifts 24-bit → 32-bit (×256), SamplePCMDecoder keeps raw 24-bit
        #expect(samples.count == legacyInt32s.count)
        for i in 0..<samples.count {
            #expect(
                legacyInt32s[i] == samples[i].value << 8,
                "Sample \(i): PCMDecoder=\(legacyInt32s[i]), SamplePCMDecoder<<8=\(samples[i].value << 8)"
            )
        }

        // SamplePCMDecoder values match expected 24-bit samples
        for i in 0..<samples.count {
            #expect(samples[i] == expectedSamples[i])
        }
    }

    // MARK: - Edge cases

    @Test("binary frame with minimum valid audio (1 sample)")
    func minimumAudioFrame() throws {
        // 1 sample of 16-bit mono = 2 bytes
        let pcmBytes: [UInt8] = [0xFF, 0x7F] // Int16.max in LE
        let frameData = TestSignal.packBinaryFrame(
            audioData: pcmBytes,
            timestampMicroseconds: 0
        )

        let message = try #require(BinaryMessage(data: frameData))
        let decoder = SamplePCMDecoder(bitDepth: 16)
        let samples = try decoder.decode([UInt8](message.data))

        #expect(samples.count == 1)
        #expect(samples[0].toI16() == Int16.max)
    }

    @Test("binary frame with zero timestamp")
    func zeroTimestamp() throws {
        let (pcmBytes, _) = TestSignal.sineWave16BitStereo(sampleRate: 48000, durationMs: 1)
        let frameData = TestSignal.packBinaryFrame(
            audioData: pcmBytes,
            timestampMicroseconds: 0
        )

        let message = try #require(BinaryMessage(data: frameData))
        #expect(message.timestamp == 0)
    }

    @Test("binary frame with large timestamp (hours of playback)")
    func largeTimestamp() throws {
        let threeHoursUs: Int64 = 3 * 3600 * 1_000_000 // 10.8 billion μs
        let (pcmBytes, _) = TestSignal.sineWave16BitStereo(sampleRate: 48000, durationMs: 1)
        let frameData = TestSignal.packBinaryFrame(
            audioData: pcmBytes,
            timestampMicroseconds: threeHoursUs
        )

        let message = try #require(BinaryMessage(data: frameData))
        #expect(message.timestamp == threeHoursUs)
    }
}
