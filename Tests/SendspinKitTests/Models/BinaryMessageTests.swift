import Foundation
@testable import SendspinKit
import Testing

@Suite("Binary Message Tests")
struct BinaryMessageTests {
    @Test("Decode audio chunk binary message with type 1")
    func audioChunkDecoding() throws {
        var data = Data()
        data.append(1) // Type: audio chunk (server uses type 1)

        // Timestamp: 1234567890 microseconds (big-endian int64)
        let timestamp: Int64 = 1_234_567_890
        withUnsafeBytes(of: timestamp.bigEndian) { data.append(contentsOf: $0) }

        // Audio data
        let audioData = Data([0x01, 0x02, 0x03, 0x04])
        data.append(audioData)

        let message = try #require(BinaryMessage(data: data))

        #expect(message.type == .audioChunk)
        #expect(message.timestamp == 1_234_567_890)
        #expect(message.data == audioData)
    }

    @Test("Decode artwork binary message")
    func artworkDecoding() throws {
        var data = Data()
        data.append(4) // Type: artwork channel 0

        let timestamp: Int64 = 9_876_543_210
        withUnsafeBytes(of: timestamp.bigEndian) { data.append(contentsOf: $0) }

        let imageData = Data([0xFF, 0xD8, 0xFF, 0xE0]) // JPEG header
        data.append(imageData)

        let message = try #require(BinaryMessage(data: data))

        #expect(message.type == .artworkChannel0)
        #expect(message.timestamp == 9_876_543_210)
        #expect(message.data == imageData)
    }

    @Test("Reject message with invalid type")
    func invalidType() {
        var data = Data()
        data.append(255) // Invalid type

        let timestamp: Int64 = 1000
        withUnsafeBytes(of: timestamp.bigEndian) { data.append(contentsOf: $0) }

        #expect(BinaryMessage(data: data) == nil)
    }

    @Test("Reject message that is too short")
    func tooShort() {
        let data = Data([0, 1, 2, 3]) // Only 4 bytes, need at least 9

        #expect(BinaryMessage(data: data) == nil)
    }
}
