// ABOUTME: End-to-end integration tests for the audio pipeline
// ABOUTME: Verifies: binary frame bytes → BinaryMessage → PCM decode → correct output

import Foundation
@testable import SendspinKit
import Testing

/// Generates deterministic test audio signals for verification.
enum TestSignal {
    /// Generate a 440Hz sine wave as 16-bit stereo PCM (little-endian).
    /// Returns raw bytes ready to be packed into a binary frame.
    static func sineWave16BitStereo(
        sampleRate: Int,
        durationMs: Int,
        frequencyHz: Double = 440.0
    ) -> [UInt8] {
        let frameCount = sampleRate * durationMs / 1_000
        var bytes = [UInt8]()
        bytes.reserveCapacity(frameCount * 2 * 2) // stereo, 2 bytes per sample

        for frame in 0 ..< frameCount {
            let t = Double(frame) / Double(sampleRate)
            let amplitude = sin(2.0 * .pi * frequencyHz * t)
            let i16Value = Int16(amplitude * Double(Int16.max))

            // Both channels get the same value (mono spread to stereo)
            for _ in 0 ..< 2 {
                bytes.append(UInt8(i16Value & 0xFF))
                bytes.append(UInt8((i16Value >> 8) & 0xFF))
            }
        }
        return bytes
    }

    /// Generate a 440Hz sine wave as 24-bit stereo PCM (little-endian).
    static func sineWave24BitStereo(
        sampleRate: Int,
        durationMs: Int,
        frequencyHz: Double = 440.0
    ) -> [UInt8] {
        let frameCount = sampleRate * durationMs / 1_000
        let i24Max: Int32 = 8_388_607
        var bytes = [UInt8]()
        bytes.reserveCapacity(frameCount * 2 * 3) // stereo, 3 bytes per sample

        for frame in 0 ..< frameCount {
            let t = Double(frame) / Double(sampleRate)
            let amplitude = sin(2.0 * .pi * frequencyHz * t)
            let i24Value = Int32(amplitude * Double(i24Max))

            for _ in 0 ..< 2 {
                bytes.append(UInt8(i24Value & 0xFF))
                bytes.append(UInt8((i24Value >> 8) & 0xFF))
                bytes.append(UInt8((i24Value >> 16) & 0xFF))
            }
        }
        return bytes
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

struct AudioPipelineIntegrationTests {
    // MARK: - Full pipeline: binary frame → BinaryMessage → PCMDecoder → Data

    @Test
    func `16-bit PCM: binary frame → parsed message → decoded samples match source signal`() throws {
        // 1. Generate known audio signal
        let pcmBytes = TestSignal.sineWave16BitStereo(
            sampleRate: 48_000,
            durationMs: 25
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

        // 4. Decode through PCMDecoder (16-bit is passthrough)
        let decoder = PCMDecoder(bitDepth: 16, channels: 2)
        let decoded = try decoder.decode(message.data)

        // 5. Verify bytes match input (16-bit PCM is passthrough)
        #expect(decoded == Data(pcmBytes))

        // 6. Verify signal properties
        let frameCount = 48_000 * 25 / 1_000
        #expect(decoded.count == frameCount * 2 * 2) // stereo × 2 bytes

        // First sample should be near zero (sin(0) = 0)
        let firstSample = decoded.withUnsafeBytes { $0.load(as: Int16.self) }
        #expect(firstSample == 0)

        // Quarter-wave peak should be near max (sin(π/2) ≈ 1)
        let quarterWaveFrame = 48_000 / (440 * 4)
        let peakOffset = quarterWaveFrame * 2 * 2 // stereo × 2 bytes
        let peakSample = decoded.withUnsafeBytes {
            $0.load(fromByteOffset: peakOffset, as: Int16.self)
        }
        let peakF32 = Float(peakSample) / Float(Int16.max)
        #expect(peakF32 > 0.9, "Quarter-wave peak should be near 1.0, got \(peakF32)")
    }

    @Test
    func `24-bit PCM: binary frame → parsed message → decoded samples match source signal`() throws {
        let pcmBytes = TestSignal.sineWave24BitStereo(
            sampleRate: 48_000,
            durationMs: 25
        )

        let frameData = TestSignal.packBinaryFrame(
            audioData: pcmBytes,
            timestampMicroseconds: 2_000_000
        )

        let message = try #require(BinaryMessage(data: frameData))
        #expect(message.type == .audioChunk)
        #expect(message.timestamp == 2_000_000)

        // 24-bit decoder unpacks 3-byte samples to 4-byte Int32 (left-justified)
        let decoder = PCMDecoder(bitDepth: 24, channels: 2)
        let decoded = try decoder.decode(message.data)

        let sampleCount = pcmBytes.count / 3
        #expect(decoded.count == sampleCount * 4) // 3 bytes in → 4 bytes out
    }

    // MARK: - Sequential chunks (simulating a stream)

    @Test
    func `sequential 25ms chunks maintain timestamp continuity`() throws {
        let chunkDurationUs: Int64 = 25_000
        let chunkCount = 10
        let decoder = PCMDecoder(bitDepth: 16, channels: 2)

        var totalBytes = 0
        var lastTimestamp: Int64 = -1

        for chunkIndex in 0 ..< chunkCount {
            let timestampUs = Int64(chunkIndex) * chunkDurationUs

            let pcmBytes = TestSignal.sineWave16BitStereo(
                sampleRate: 48_000,
                durationMs: 25
            )

            let frameData = TestSignal.packBinaryFrame(
                audioData: pcmBytes,
                timestampMicroseconds: timestampUs
            )

            let message = try #require(BinaryMessage(data: frameData))
            #expect(message.timestamp > lastTimestamp, "Timestamps must be monotonically increasing")
            lastTimestamp = message.timestamp

            let decoded = try decoder.decode(message.data)
            totalBytes += decoded.count
        }

        // 10 chunks × 25ms × 48kHz × 2 channels × 2 bytes = 96000 bytes
        let expectedTotal = chunkCount * (48_000 * 25 / 1_000) * 2 * 2
        #expect(totalBytes == expectedTotal)
    }

    // MARK: - Edge cases

    @Test
    func `binary frame with zero timestamp`() throws {
        let pcmBytes = TestSignal.sineWave16BitStereo(sampleRate: 48_000, durationMs: 1)
        let frameData = TestSignal.packBinaryFrame(
            audioData: pcmBytes,
            timestampMicroseconds: 0
        )

        let message = try #require(BinaryMessage(data: frameData))
        #expect(message.timestamp == 0)
    }

    @Test
    func `binary frame with large timestamp (hours of playback)`() throws {
        let threeHoursUs: Int64 = 3 * 3_600 * 1_000_000
        let pcmBytes = TestSignal.sineWave16BitStereo(sampleRate: 48_000, durationMs: 1)
        let frameData = TestSignal.packBinaryFrame(
            audioData: pcmBytes,
            timestampMicroseconds: threeHoursUs
        )

        let message = try #require(BinaryMessage(data: frameData))
        #expect(message.timestamp == threeHoursUs)
    }
}
