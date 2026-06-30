import Foundation
@testable import SendspinKit
import Testing

struct OpusDecoderTests {
    /// RFC 6716 Appendix B: Opus packet for one frame of silence.
    private static let silencePacket = Data([0xFC, 0xFF, 0xFE])
    private static let bytesPerSample = MemoryLayout<Int32>.size
    private static let stereoChannels = 2
    private static let frameDurationFrames = 960 // 20 ms at 48 kHz

    @Test
    func decodeSilenceProducesInterleavedInt32() throws {
        let decoder = try AudioDecoderFactory.create(
            codec: .opus,
            sampleRate: 48_000,
            channels: Self.stereoChannels,
            bitDepth: 16,
            header: nil
        )

        let first = try decoder.decode(Self.silencePacket)
        #expect(!first.isEmpty)
        assertInt32Silence(first)

        let second = try decoder.decode(Self.silencePacket)
        #expect(second.count == Self.frameDurationFrames * Self.stereoChannels * Self.bytesPerSample)
        assertInt32Silence(second)
    }

    @Test
    func allStandardSampleRatesCanCreateDecoder() throws {
        for sampleRate in [8_000, 12_000, 16_000, 24_000, 48_000] {
            _ = try AudioDecoderFactory.create(
                codec: .opus,
                sampleRate: sampleRate,
                channels: 2,
                bitDepth: 16,
                header: nil
            )
        }
    }

    private func assertInt32Silence(_ data: Data) {
        #expect(data.count.isMultiple(of: Self.stereoChannels * Self.bytesPerSample))
        let samples = data.withUnsafeBytes { Array($0.bindMemory(to: Int32.self)) }
        #expect(samples.allSatisfy { $0 == 0 })
    }
}
