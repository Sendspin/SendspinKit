import Foundation
@testable import SendspinKit
import Testing

/// `writeCallback` iterates channels over a C array of exactly `frame.header.channels`
/// pointers. Iterating by the *announced* count instead (wire data, checked only against
/// `AudioFormatSpec.maxChannels` = 32) read out of bounds.
///
/// Uses real libFLAC-encoded streams: only a stream libFLAC actually decodes reaches the
/// callback where the bug lives.
struct FLACChannelSafetyTests {
    /// Complete 1-channel FLAC stream (magic + STREAMINFO + comment + one frame).
    static let monoFLAC = Data(base64Encoded: [
        "ZkxhQwAAACIQABAAAAKTAAKTCsRA8AAACJ0dJi5K1u7pVRchehGT7NQBAwAAEgAAAAAAAAAAAAAAAAAAAAAInYQAACggAAAAcmVm",
        "ZXJlbmNlIGxpYkZMQUMgMS41LjAgMjAyNTAyMTEAAAAA//h5CAAInBRCAAABALU/5gAAE00mcpKZ/yUKZkpKYFDIcJmZOGZMkhky",
        "ZyckuSnnk8nmSlKecmhKZkyZMmZQzhyUJhhM5knJKTmZzJhQoUKFJl5SZyFkyZzMlOYUkzOSSSThQoZmZkyUJOEpyUKHnp4ULMyc",
        "LJZQuTChQ8mYZIYUmHDk5JMJhkPmeZzNLM5KSk5phhkMhQnhmGZMJhMyUmUklJZTyIShlChZmXznDmckyYZhmZhSTMmSSSZM4cPK",
        "FJTOTMzhTM6fChznhnDKHM4cMnMmQwyUMzkzlCcOTJKYWFJkpZTM8KZM5SUz4ZmZkyTCTCkw5PJhkwyTCyZySk/5lJTJyheUpkmS",
        "hMnChkkhyZmGZhkpSz8meeSnShTChSShYZMCkkw5KTChmYYYTkKZOSeUznmToFM5lLnMyk5JOTMKHM4UmZkmEk5mSZKFJmZmZKFM",
        "5k+nJ4UmZkpOcwuYUOTJkMkOShOTJQ4ZMwnDnJyUlNKZnkpJz8/MmZnJwwmGFMJmTkkmQmGSlChZKHkvnOSmc0KEyGSSZmTJhSSS",
        "SZJQpOSgU8plKFJk5QpPTzmSklMmHJJk5kzMmYZDJKTMyZzKHnChmZnMKUpTJws5w5mFMykwoZOcJhJmZOSUnJKGTMMyhzOf5lCm",
        "ZSTlOeaFDCmchSSSFCUMmYUzJJJkMmcwpwplOnJTzJTLKWUMCk5JhYZhkMOThmTDPKaecnOeFlLJScOZoZJMhQyZ4UMnJMJJkzMn",
        "DPPJSUmFk5mf8mZzKGZCmZOTQzKGcMkhwpMzMpk5MnJmczkymnk5nMOc8lCwoZmThwwwwpJmShScMkmSgecmcKcuUlClAiSUKeWS",
        "Jkk8kzJwkknDmFDMmGFAs7w="
    ].joined())!

    /// The same stream encoded with 2 channels.
    private static let stereoFLAC = Data(base64Encoded: [
        "ZkxhQwAAACIQABAAAALDAALDCsRC8AAACJ2isbHC6zbp713avjHS7RNdAwAAEgAAAAAAAAAAAAAAAAAAAAAInYQAACggAAAAcmVm",
        "ZXJlbmNlIGxpYkZMQUMgMS41LjAgMjAyNTAyMTEAAAAA//h5iAAInCVCAAAAtbU/5gAAEOTkzM5nDh5lChSZmgUyESckoZSShKZL",
        "DJhQoZw5JmUkocyTmckyZmTSEQycKShwoUMpkNDMoU5OYZk5CzMlJmUMphSUCkw8mUOclDQlJIhKSUMKHhSUzkIhyaQpMKShQkQM",
        "ykoUMpMoFChQsMzKBYeYUmFChQlJMKGhoZk5KQ8kpkyUyclDzhzIWZycmZwoZyUMphSZM5lCUJSFCkzJnJkoczMKSmHJKZoZScyk",
        "oZQKTJlMnIWZQphTMMzKFDk5OUKFJSckoTMzPMoZQyUKTOHDIWYeUKTOQphQlMhZKTJyhocKTJklJlDMOc5KGcwoZmZkpQ8mYWFJ",
        "wpMKShzQKTQ8lMKGSmZwzKBTJQocnKE5Mw8zkKTMyUKQiEpQOUMKTOZyFJnOZyaBZhTOFhKZKHJlCkzJMwocKHDOTSZmTJoUCkyF",
        "knnMOZzMmZMoTKEpKZwpKEmZmYUzJzOc4UmTMOc4ecLDkygUoUMOchZzKEpCIeQiEycLDSckQnQ5QlDOTmFJzChycmZkyUMmcIhQ",
        "KUDlDKThYSkzMIgWQsLJmSaGkKZkpCmYUzOSkIhKGZQpkmShOcMnCmEQzOTJQ8koYWeSk5zCmYclCUzKHDzycKTMOZKSkyhnhQsn",
        "ChQySkznnCkzCIZlJMkyUmaHk5CkzDmQiHMw8KcwphQzIUocmTkpycKHChmTMmHksMKShQoczM4UlJmcmhpDkzKThQ5hYZyhhTmS",
        "hKSFKTMyZPDOTM5Mzk5OZQlCUKczmczkzM4eFMnChEM0OZkmUKFMycIhyZlJKTMOFJKFOZmQiGZKScKFDOSU4RIUnDkzklJkzOTQ",
        "oUnJhQwiGc5JzOZhQpKTJk0JTPMOSkoUMpMkpIgUoFkoWFKQ5M5mFhIhQlDmFMmZw4Uh5KThwoUmZQoUAAAA1/A="
    ].joined())!

    // MARK: - Construction-time channel validation

    /// The reachable wire case: an announced count FLAC cannot encode.
    @Test("FLAC decoder rejects an announced channel count above the FLAC maximum")
    func rejectsChannelCountAboveFLACMaximum() {
        for channels in [FLACDecoder.maxFLACChannels + 1, 16, AudioFormatSpec.maxChannels] {
            #expect(throws: (any Error).self) {
                _ = try FLACDecoder(sampleRate: 44_100, channels: channels, bitDepth: 16)
            }
        }
    }

    @Test("FLAC decoder rejects a non-positive channel count")
    func rejectsNonPositiveChannelCount() {
        #expect(throws: (any Error).self) {
            _ = try FLACDecoder(sampleRate: 44_100, channels: 0, bitDepth: 16)
        }
    }

    /// Every channel count representable by FLAC remains accepted.
    @Test("FLAC decoder still accepts every channel count FLAC can represent")
    func acceptsAllRepresentableChannelCounts() throws {
        for channels in 1 ... FLACDecoder.maxFLACChannels {
            _ = try FLACDecoder(sampleRate: 44_100, channels: channels, bitDepth: 16)
        }
    }

    // MARK: - Frame-header vs announced mismatch

    /// The frame-header channel count must be validated before interleaving samples.
    @Test("a mono stream announced as stereo is refused, not read out of bounds")
    func monoStreamAnnouncedAsStereoIsRefused() throws {
        let decoder = try FLACDecoder(sampleRate: 44_100, channels: 2, bitDepth: 16)

        // Assert the reason: a generic "stalled" error would pass without proving the
        // channel bound is what rejected the frame.
        let error = #expect(throws: AudioDecoderError.self) {
            _ = try decoder.decode(Self.monoFLAC)
        }
        guard case let .channelCountMismatch(announced, actual) = error else {
            Issue.record("expected .channelCountMismatch, got \(String(describing: error))")
            return
        }
        #expect(announced == 2, "the announced count comes from stream/start")
        #expect(actual == 1, "the actual count comes from the FLAC frame header")
    }

    /// The inverse under-reads rather than over-reads, but the layout is still wrong.
    @Test("a stereo stream announced as mono is refused")
    func stereoStreamAnnouncedAsMonoIsRefused() throws {
        let decoder = try FLACDecoder(sampleRate: 44_100, channels: 1, bitDepth: 16)

        let error = #expect(throws: AudioDecoderError.self) {
            _ = try decoder.decode(Self.stereoFLAC)
        }
        guard case let .channelCountMismatch(announced, actual) = error else {
            Issue.record("expected .channelCountMismatch, got \(String(describing: error))")
            return
        }
        #expect(announced == 1)
        #expect(actual == 2)
    }

    // MARK: - Matching streams must still decode

    /// Without this, the "is refused" tests would pass if the decoder rejected everything.
    @Test("a stereo stream announced as stereo decodes to interleaved Int32 samples")
    func matchingStereoStreamDecodes() throws {
        let decoder = try FLACDecoder(sampleRate: 44_100, channels: 2, bitDepth: 16)

        let pcm = try decoder.decode(Self.stereoFLAC)

        #expect(!pcm.isEmpty, "a matching stream must produce audio")
        // libFLAC output is Int32 per sample, interleaved across 2 channels.
        let bytesPerFrame = 2 * MemoryLayout<Int32>.size
        #expect(pcm.count % bytesPerFrame == 0, "output must be whole interleaved stereo frames")
    }

    @Test("a mono stream announced as mono decodes to Int32 samples")
    func matchingMonoStreamDecodes() throws {
        let decoder = try FLACDecoder(sampleRate: 44_100, channels: 1, bitDepth: 16)

        let pcm = try decoder.decode(Self.monoFLAC)

        #expect(!pcm.isEmpty, "a matching stream must produce audio")
        #expect(pcm.count % MemoryLayout<Int32>.size == 0, "output must be whole Int32 samples")
    }
}
