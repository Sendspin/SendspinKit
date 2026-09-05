import Foundation
@testable import SendspinKit
import Testing

struct BinaryMessageTests {
    /// Helper to build a binary message frame from components.
    private static func makeFrame(type: UInt8, timestamp: Int64, payload: Data = Data()) -> Data {
        var data = Data([type])
        if type == BinaryMessageType.audioChunk.rawValue {
            withUnsafeBytes(of: timestamp.bigEndian) { data.append(contentsOf: $0) }
            data.append(contentsOf: [0, 0, 0, 0])
        } else if type == BinaryMessageType.visualizerData.rawValue {
            withUnsafeBytes(of: timestamp.bigEndian) { data.append(contentsOf: $0) }
        } else if type >= BinaryMessageType.artworkChannel0.rawValue,
                  type <= BinaryMessageType.artworkChannel3.rawValue {
            data.append(payload)
            return data
        }
        data.append(payload)
        return data
    }

    // MARK: - Valid messages

    @Test
    func decodeAudioChunkBinaryMessage() throws {
        let audioData = Data([0x01, 0x02, 0x03, 0x04])
        let frame = Self.makeFrame(
            type: BinaryMessageType.audioChunk.rawValue,
            timestamp: 1_234_567_890,
            payload: audioData
        )

        let message = try #require(BinaryMessage(data: frame))

        #expect(message.type == .audioChunk)
        #expect(message.timestamp == 1_234_567_890)
        #expect(message.sendAhead == 0)
        #expect(message.data == audioData)
    }

    @Test
    func decodeArtworkBinaryMessage() throws {
        let imageData = Data([0xFF, 0xD8, 0xFF, 0xE0]) // JPEG header
        let frame = Self.makeFrame(
            type: BinaryMessageType.artworkChannel0.rawValue,
            timestamp: 9_876_543_210,
            payload: imageData
        )

        let message = try #require(BinaryMessage(data: frame))

        #expect(message.type == .artworkChannel0)
        #expect(message.timestamp == 0)
        #expect(message.data == imageData)
    }

    @Test(arguments: [
        (BinaryMessageType.artworkChannel0, 0),
        (BinaryMessageType.artworkChannel1, 1),
        (BinaryMessageType.artworkChannel2, 2),
        (BinaryMessageType.artworkChannel3, 3)
    ])
    func decodeArtworkChannel(type: BinaryMessageType, expectedChannel: Int) throws {
        let frame = Self.makeFrame(
            type: type.rawValue,
            timestamp: 1_000_000,
            payload: Data([0x00])
        )

        let message = try #require(BinaryMessage(data: frame))
        #expect(message.type == type)
        #expect(message.timestamp == 0)
        #expect(message.data == Data([0x00]))
        #expect(message.type.artworkChannel == expectedChannel)
    }

    @Test
    func decodeVisualizerDataMessage() throws {
        let fftData = Data([0x10, 0x20, 0x30, 0x40])
        let frame = Self.makeFrame(
            type: BinaryMessageType.visualizerData.rawValue,
            timestamp: 5_000_000,
            payload: fftData
        )

        let message = try #require(BinaryMessage(data: frame))

        #expect(message.type == .visualizerData)
        #expect(message.timestamp == 5_000_000)
        #expect(message.data == fftData)
    }

    @Test
    func decodeMessageWithEmptyPayload() throws {
        // Per spec: empty artwork message clears the display
        let frame = Self.makeFrame(
            type: BinaryMessageType.artworkChannel0.rawValue,
            timestamp: 2_000_000
        )

        let message = try #require(BinaryMessage(data: frame))
        #expect(message.timestamp == 0)
        #expect(message.data.isEmpty)
    }

    // MARK: - artworkChannel computed property

    @Test
    func artworkChannel_returnsCorrectIndexForArtworkTypes() {
        #expect(BinaryMessageType.artworkChannel0.artworkChannel == 0)
        #expect(BinaryMessageType.artworkChannel1.artworkChannel == 1)
        #expect(BinaryMessageType.artworkChannel2.artworkChannel == 2)
        #expect(BinaryMessageType.artworkChannel3.artworkChannel == 3)
    }

    @Test
    func artworkChannel_returnsNilForNonArtworkTypes() {
        #expect(BinaryMessageType.audioChunk.artworkChannel == nil)
        #expect(BinaryMessageType.visualizerData.artworkChannel == nil)
    }

    // MARK: - Timestamp edge cases

    @Test
    func acceptZeroTimestamp() throws {
        let frame = Self.makeFrame(
            type: BinaryMessageType.audioChunk.rawValue,
            timestamp: 0
        )
        let message = try #require(BinaryMessage(data: frame))
        #expect(message.timestamp == 0)
    }

    @Test
    func acceptMaximumTimestamp() throws {
        let frame = Self.makeFrame(
            type: BinaryMessageType.audioChunk.rawValue,
            timestamp: Int64.max
        )
        let message = try #require(BinaryMessage(data: frame))
        #expect(message.timestamp == Int64.max)
    }

    @Test
    func rejectNegativeTimestamp() {
        let frame = Self.makeFrame(
            type: BinaryMessageType.audioChunk.rawValue,
            timestamp: -1
        )
        #expect(BinaryMessage(data: frame) == nil)
    }

    @Test
    func rejectMinimumNegativeTimestamp() {
        let frame = Self.makeFrame(
            type: BinaryMessageType.audioChunk.rawValue,
            timestamp: Int64.min
        )
        #expect(BinaryMessage(data: frame) == nil)
    }

    // MARK: - Rejection

    @Test
    func rejectMessageWithUnknownType() {
        let frame = Self.makeFrame(type: 255, timestamp: 1_000)
        #expect(BinaryMessage(data: frame) == nil)
    }

    @Test
    func rejectReservedTypeID() {
        for reservedType in [UInt8(0), UInt8(1), UInt8(3)] {
            let frame = Self.makeFrame(type: reservedType, timestamp: 1_000)
            #expect(BinaryMessage(data: frame) == nil)
        }
    }

    @Test
    func decodeDigitAudioClip() throws {
        let frame = Data([BinaryMessageType.digitAudioClip.rawValue, 7, 0xF0, 0x0D])
        let message = try #require(BinaryMessage(data: frame))
        #expect(message.type == .digitAudioClip)
        #expect(message.digit == 7)
        #expect(message.timestamp == 0)
        #expect(message.data == Data([0xF0, 0x0D]))
    }

    @Test(arguments: [UInt32(0), UInt32.max])
    func decodeSendAheadSaturation(sendAhead: UInt32) throws {
        var frame = Data([BinaryMessageType.audioChunk.rawValue])
        frame.append(contentsOf: [0, 0, 0, 0, 0, 0, 0, 1])
        withUnsafeBytes(of: sendAhead.bigEndian) { frame.append(contentsOf: $0) }
        frame.append(contentsOf: [0xAA, 0xBB])
        let message = try #require(BinaryMessage(data: frame))
        #expect(message.timestamp == 1)
        #expect(message.sendAhead == sendAhead)
        #expect(message.data == Data([0xAA, 0xBB]))
    }

    @Test
    func rejectEmptyData() {
        #expect(BinaryMessage(data: Data()) == nil)
    }

    @Test
    func rejectMessageShorterThanHeader() {
        let data = Data([0, 1, 2, 3])
        #expect(BinaryMessage(data: data) == nil)
    }

    @Test
    func rejectMessageWithExactlyHeaderSizeMinusOne() {
        let data = Data(repeating: 0, count: BinaryMessage.headerSize - 1)
        #expect(BinaryMessage(data: data) == nil)
    }

    @Test
    func acceptMessageWithExactlyHeaderSizeNoPayload() throws {
        let frame = Self.makeFrame(
            type: BinaryMessageType.audioChunk.rawValue,
            timestamp: 1_000_000
        )
        #expect(frame.count == BinaryMessage.audioChunkHeaderSize)
        let message = try #require(BinaryMessage(data: frame))
        #expect(message.data.isEmpty)
    }

    // MARK: - Header size

    @Test
    func headerSizeMatchesSpec1ByteTypePlus8BytesTimestamp() {
        // Spec anchor: documents that headerSize is intentionally 9.
        #expect(BinaryMessage.headerSize == 9)
    }

    /// Every other test here uses these symbolically, which is right — but it means
    /// renumbering a case keeps the suite green while breaking interop. Exactly one test
    /// must pin the literals, as `headerSize` is pinned above.
    @Test
    func binaryTypeBytesMatchSpecValues() {
        #expect(NoiseFrameType.fragment == 1)
        #expect(NoiseFragmentFlags.first == 0b10)
        #expect(NoiseFragmentFlags.last == 0b01)
        #expect(NoiseFragmentFlags.reservedMask == 0b1111_1100)
        #expect(BinaryMessageType.digitAudioClip.rawValue == 2)
        #expect(BinaryMessageType.audioChunk.rawValue == 4)
        #expect(BinaryMessageType.artworkChannel0.rawValue == 8)
        #expect(BinaryMessageType.artworkChannel1.rawValue == 9)
        #expect(BinaryMessageType.artworkChannel2.rawValue == 10)
        #expect(BinaryMessageType.artworkChannel3.rawValue == 11)
        #expect(BinaryMessageType.visualizerData.rawValue == 16)
    }

    @Test
    func handDerivedAudioChunkFixtureDecodesAllFields() throws {
        // Type 4 layout: type, eight-byte big-endian timestamp, four-byte send_ahead, payload.
        let frame = Data([
            4,
            0x00, 0x00, 0x00, 0x00, 0x00, 0x0F, 0x42, 0x40,
            0x00, 0x00, 0x03, 0xE8,
            0xDE, 0xAD, 0xBE, 0xEF
        ])
        let message = try #require(BinaryMessage(data: frame))
        #expect(message.timestamp == 1_000_000)
        #expect(message.sendAhead == 1_000)
        #expect(message.data == Data([0xDE, 0xAD, 0xBE, 0xEF]))
        #expect(frame[13] == message.data[0])
    }

    @Test(arguments: [
        Data([8, 0b01]),
        Data([9, 0b10, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x03]),
        Data([10, 0x00, 0xCA, 0xFE])
    ])
    func artworkTransferShapesRemainOpaque(frame: Data) throws {
        let message = try #require(BinaryMessage(data: frame))
        #expect(message.data == Data(frame.dropFirst()))
        #expect(message.timestamp == 0)
    }

    /// The routing code maps a channel index onto these, so they must stay contiguous.
    @Test
    func artworkChannelTypeBytesAreContiguous() {
        let artworkTypes: [BinaryMessageType] = [
            .artworkChannel0, .artworkChannel1, .artworkChannel2, .artworkChannel3
        ]
        for (index, type) in artworkTypes.enumerated() {
            #expect(
                type.rawValue == BinaryMessageType.artworkChannel0.rawValue + UInt8(index),
                "artwork channel \(index) must be contiguous with channel 0"
            )
        }
    }
}
