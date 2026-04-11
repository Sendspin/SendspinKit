// ABOUTME: PCM decoder that produces Sample values
// ABOUTME: Supports 16-bit and 24-bit PCM, silently drops trailing bytes

import Foundation

/// PCM decoder that produces typed Sample values
public struct SamplePCMDecoder: Sendable {
    private let bitDepth: Int

    public init(bitDepth: Int) {
        self.bitDepth = bitDepth
    }

    /// Decode raw PCM bytes into Sample values.
    /// Trailing bytes that don't form a complete sample are silently dropped.
    public func decode(_ data: [UInt8]) throws -> [Sample] {
        switch bitDepth {
        case 16:
            return decode16Bit(data)
        case 24:
            return decode24Bit(data)
        default:
            throw SamplePCMDecoderError.unsupportedBitDepth(bitDepth)
        }
    }

    private func decode16Bit(_ data: [UInt8]) -> [Sample] {
        let bytesPerSample = 2
        let sampleCount = data.count / bytesPerSample
        var samples = [Sample]()
        samples.reserveCapacity(sampleCount)

        for i in 0..<sampleCount {
            let offset = i * bytesPerSample
            let raw = Int16(data[offset]) | (Int16(data[offset + 1]) << 8)
            samples.append(Sample.fromI16(raw))
        }

        return samples
    }

    private func decode24Bit(_ data: [UInt8]) -> [Sample] {
        let bytesPerSample = 3
        let sampleCount = data.count / bytesPerSample
        var samples = [Sample]()
        samples.reserveCapacity(sampleCount)

        for i in 0..<sampleCount {
            let offset = i * bytesPerSample
            let bytes: [UInt8] = [data[offset], data[offset + 1], data[offset + 2]]
            samples.append(Sample.fromI24LE(bytes))
        }

        return samples
    }
}

public enum SamplePCMDecoderError: Error {
    case unsupportedBitDepth(Int)
}
