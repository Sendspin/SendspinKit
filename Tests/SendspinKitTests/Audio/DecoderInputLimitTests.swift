import Foundation
@testable import SendspinKit
import Testing

/// Both decoders sized allocations straight from wire payloads: Opus via
/// `maximumPacketSize: data.count`, FLAC via a `pendingData` buffer that only compacts
/// once libFLAC consumes half of it.
struct DecoderInputLimitTests {
    // MARK: - Opus

    @Test("an oversized Opus packet is rejected rather than sizing a buffer from it")
    func oversizedOpusPacketIsRejected() throws {
        let decoder = try OpusDecoder(sampleRate: 48_000, channels: 2, bitDepth: 16)
        let overBy = 1
        let oversized = Data(repeating: 0xFF, count: OpusDecoder.maximumOpusPacketBytes + overBy)

        let error = #expect(throws: AudioDecoderError.self) {
            _ = try decoder.decode(oversized)
        }

        guard case let .inputTooLarge(bytes, limit) = error else {
            Issue.record("expected .inputTooLarge, got \(String(describing: error))")
            return
        }
        #expect(bytes == OpusDecoder.maximumOpusPacketBytes + overBy)
        #expect(limit == OpusDecoder.maximumOpusPacketBytes)
    }

    /// Pins the boundary: one byte lower must not be rejected for size, or the guard is
    /// off by one and would drop legitimate packets.
    @Test("a packet at the limit is not rejected by the size guard")
    func packetAtLimitPassesTheSizeGuard() throws {
        let decoder = try OpusDecoder(sampleRate: 48_000, channels: 2, bitDepth: 16)
        let atLimit = Data(repeating: 0xFF, count: OpusDecoder.maximumOpusPacketBytes)

        // Not valid Opus, so it may still fail — just not for size.
        do {
            _ = try decoder.decode(atLimit)
        } catch let error as AudioDecoderError {
            if case .inputTooLarge = error {
                Issue.record("a packet exactly at the limit must not be rejected for size")
            }
        }
    }

    // MARK: - FLAC

    @Test("FLAC pending data cannot grow without bound on an unparseable stream")
    func flacPendingDataIsBounded() throws {
        let decoder = try FLACDecoder(sampleRate: 44_100, channels: 2, bitDepth: 16)

        // Larger than the cap, so unconsumed bytes exceed it however much libFLAC skips.
        let chunk = Data(repeating: 0x00, count: FLACDecoder.maximumPendingBytes + 1)
        var sawOverflowRejection = false
        for _ in 0 ..< 8 {
            do {
                _ = try decoder.decode(chunk)
            } catch let error as AudioDecoderError {
                if case .inputTooLarge = error {
                    sawOverflowRejection = true
                    break
                }
                // Other decode failures are expected for garbage input; keep feeding.
            }
        }

        #expect(
            sawOverflowRejection,
            "an unparseable stream must eventually be rejected instead of growing the buffer forever"
        )
    }

    /// The cap is compared against buffered-plus-incoming. Checking only what is already
    /// buffered lets the very first oversized payload through, allocating past the bound
    /// before any check runs.
    @Test("a single oversized FLAC payload is rejected on its first decode")
    func oversizedFLACPayloadIsRejectedImmediately() throws {
        let decoder = try FLACDecoder(sampleRate: 44_100, channels: 2, bitDepth: 16)
        let oversized = Data(repeating: 0x00, count: FLACDecoder.maximumPendingBytes + 1)

        let error = #expect(throws: AudioDecoderError.self) {
            _ = try decoder.decode(oversized)
        }

        guard case let .inputTooLarge(_, limit) = error else {
            Issue.record("expected .inputTooLarge on the first oversized payload, got \(String(describing: error))")
            return
        }
        #expect(limit == FLACDecoder.maximumPendingBytes)
    }
}
