// ABOUTME: Tests for binary message decoding from WebSocket frames
// ABOUTME: Validates type parsing, timestamp extraction, payload slicing, and rejection of invalid data

import Foundation
@testable import SendspinKit
import Testing

struct BinaryMessageTests {
    /// Helper to build a binary message frame from components.
    private static func makeFrame(type: UInt8, timestamp: Int64, payload: Data = Data()) -> Data {
        var data = Data()
        data.append(type)
        withUnsafeBytes(of: timestamp.bigEndian) { data.append(contentsOf: $0) }
        data.append(payload)
        return data
    }

    // MARK: - Valid messages

    @Test
    func `Decode audio chunk binary message`() throws {
        let audioData = Data([0x01, 0x02, 0x03, 0x04])
        let frame = Self.makeFrame(
            type: BinaryMessageType.audioChunk.rawValue,
            timestamp: 1_234_567_890,
            payload: audioData
        )

        let message = try #require(BinaryMessage(data: frame))

        #expect(message.type == .audioChunk)
        #expect(message.timestamp == 1_234_567_890)
        #expect(message.data == audioData)
    }

    @Test
    func `Decode artwork binary message`() throws {
        let imageData = Data([0xFF, 0xD8, 0xFF, 0xE0]) // JPEG header
        let frame = Self.makeFrame(
            type: BinaryMessageType.artworkChannel0.rawValue,
            timestamp: 9_876_543_210,
            payload: imageData
        )

        let message = try #require(BinaryMessage(data: frame))

        #expect(message.type == .artworkChannel0)
        #expect(message.timestamp == 9_876_543_210)
        #expect(message.data == imageData)
    }

    @Test(arguments: [
        (BinaryMessageType.artworkChannel0, 0),
        (BinaryMessageType.artworkChannel1, 1),
        (BinaryMessageType.artworkChannel2, 2),
        (BinaryMessageType.artworkChannel3, 3),
    ])
    func `Decode artwork channel`(type: BinaryMessageType, expectedChannel: Int) throws {
        let frame = Self.makeFrame(
            type: type.rawValue,
            timestamp: 1_000_000,
            payload: Data([0x00])
        )

        let message = try #require(BinaryMessage(data: frame))
        #expect(message.type == type)
        #expect(message.type.artworkChannel == expectedChannel)
    }

    @Test
    func `Decode visualizer data message`() throws {
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
    func `Decode message with empty payload`() throws {
        // Per spec: empty artwork message clears the display
        let frame = Self.makeFrame(
            type: BinaryMessageType.artworkChannel0.rawValue,
            timestamp: 2_000_000
        )

        let message = try #require(BinaryMessage(data: frame))
        #expect(message.data.isEmpty)
    }

    // MARK: - artworkChannel computed property

    @Test
    func `artworkChannel returns correct index for artwork types`() {
        #expect(BinaryMessageType.artworkChannel0.artworkChannel == 0)
        #expect(BinaryMessageType.artworkChannel1.artworkChannel == 1)
        #expect(BinaryMessageType.artworkChannel2.artworkChannel == 2)
        #expect(BinaryMessageType.artworkChannel3.artworkChannel == 3)
    }

    @Test
    func `artworkChannel returns nil for non-artwork types`() {
        #expect(BinaryMessageType.audioChunk.artworkChannel == nil)
        #expect(BinaryMessageType.visualizerData.artworkChannel == nil)
    }

    // MARK: - Timestamp edge cases

    @Test
    func `Accept zero timestamp`() throws {
        let frame = Self.makeFrame(
            type: BinaryMessageType.audioChunk.rawValue,
            timestamp: 0
        )
        let message = try #require(BinaryMessage(data: frame))
        #expect(message.timestamp == 0)
    }

    @Test
    func `Accept maximum timestamp`() throws {
        let frame = Self.makeFrame(
            type: BinaryMessageType.audioChunk.rawValue,
            timestamp: Int64.max
        )
        let message = try #require(BinaryMessage(data: frame))
        #expect(message.timestamp == Int64.max)
    }

    @Test
    func `Reject negative timestamp`() {
        let frame = Self.makeFrame(
            type: BinaryMessageType.audioChunk.rawValue,
            timestamp: -1
        )
        #expect(BinaryMessage(data: frame) == nil)
    }

    @Test
    func `Reject minimum negative timestamp`() {
        let frame = Self.makeFrame(
            type: BinaryMessageType.audioChunk.rawValue,
            timestamp: Int64.min
        )
        #expect(BinaryMessage(data: frame) == nil)
    }

    // MARK: - Rejection

    @Test
    func `Reject message with unknown type`() {
        let frame = Self.makeFrame(type: 255, timestamp: 1_000)
        #expect(BinaryMessage(data: frame) == nil)
    }

    @Test(arguments: UInt8(0) ... UInt8(3))
    func `Reject reserved type ID`(reservedType: UInt8) {
        // Types 0-3 are reserved per spec — 0 is intentionally reserved,
        // not a default/unset sentinel.
        let frame = Self.makeFrame(type: reservedType, timestamp: 1_000)
        #expect(BinaryMessage(data: frame) == nil)
    }

    @Test
    func `Reject empty data`() {
        #expect(BinaryMessage(data: Data()) == nil)
    }

    @Test
    func `Reject message shorter than header`() {
        let data = Data([0, 1, 2, 3])
        #expect(BinaryMessage(data: data) == nil)
    }

    @Test
    func `Reject message with exactly header size minus one`() {
        let data = Data(repeating: 0, count: BinaryMessage.headerSize - 1)
        #expect(BinaryMessage(data: data) == nil)
    }

    @Test
    func `Accept message with exactly header size (no payload)`() throws {
        let frame = Self.makeFrame(
            type: BinaryMessageType.audioChunk.rawValue,
            timestamp: 1_000_000
        )
        #expect(frame.count == BinaryMessage.headerSize)
        let message = try #require(BinaryMessage(data: frame))
        #expect(message.data.isEmpty)
    }

    // MARK: - Header size

    @Test
    func `Header size matches spec (1 byte type + 8 bytes timestamp)`() {
        // Spec anchor: documents that headerSize is intentionally 9.
        #expect(BinaryMessage.headerSize == 9)
    }
}
