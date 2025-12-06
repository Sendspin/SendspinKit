// ABOUTME: Handles decoding of binary messages from WebSocket (audio chunks, artwork, visualizer data)
// ABOUTME: Format: [type: uint8][timestamp: int64 big-endian][data: bytes...]

import Foundation

/// Binary message types using bit-packed structure
/// Bits 7-2: role type, Bits 1-0: message slot
public enum BinaryMessageType: UInt8, Sendable {
    // Player role (000000xx)
    case audioChunk = 1 // Server uses type 1 for audio chunks
    case audioChunkAlt = 0 // Legacy slot (not used by server)

    // Artwork role (000001xx)
    case artworkChannel0 = 4
    case artworkChannel1 = 5
    case artworkChannel2 = 6
    case artworkChannel3 = 7

    // Visualizer role (000010xx)
    case visualizerData = 8
}

/// Binary message from server
public struct BinaryMessage: Sendable {
    /// Message type
    public let type: BinaryMessageType
    /// Server timestamp in microseconds when this should be played/displayed
    public let timestamp: Int64
    /// Message payload (audio data, image data, etc.)
    public let data: Data

    /// Decode binary message from WebSocket data
    /// - Parameter data: Raw WebSocket binary frame
    /// - Returns: Decoded message or nil if invalid
    public init?(data: Data) {
        guard data.count >= 9 else {
            // print("[BinaryMessage] Parse failed: too short (\(data.count) bytes, need 9+)")
            return nil
        }

        let typeValue = data[0]
        guard let type = BinaryMessageType(rawValue: typeValue) else {
            // print("[BinaryMessage] Parse failed: unknown type \(typeValue)")
            return nil
        }

        self.type = type

        // Extract big-endian int64 from bytes 1-8
        let extractedTimestamp = data[1 ..< 9].withUnsafeBytes { buffer in
            buffer.loadUnaligned(as: Int64.self).bigEndian
        }

        // Validate timestamp is non-negative (server should never send negative)
        guard extractedTimestamp >= 0 else {
            // print("[BinaryMessage] Parse failed: negative timestamp \(extractedTimestamp)")
            return nil
        }

        timestamp = extractedTimestamp
        self.data = data.subdata(in: 9 ..< data.count)

        // Successfully parsed: type=\(type) timestamp=\(extractedTimestamp)
        // payloadSize=\(self.data.count)
    }
}
