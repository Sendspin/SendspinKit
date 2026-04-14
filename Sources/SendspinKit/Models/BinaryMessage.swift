// ABOUTME: Handles decoding of binary messages from WebSocket (audio chunks, artwork, visualizer data)
// ABOUTME: Format: [type: uint8][timestamp: int64 big-endian][data: bytes...]

import Foundation

/// Binary message type ID allocation per Sendspin spec:
/// - 0-3: Reserved
/// - 4-7: Player role (audio chunks)
/// - 8-11: Artwork role (channels 0-3)
/// - 16-23: Visualizer role
/// - 24-191: Reserved for future roles
/// - 192-255: Application-specific roles
enum BinaryMessageType: UInt8, Sendable {
    /// Player role (4-7).
    case audioChunk = 4

    // Artwork role (8-11) - channels 0-3
    case artworkChannel0 = 8
    case artworkChannel1 = 9
    case artworkChannel2 = 10
    case artworkChannel3 = 11

    /// Visualizer role (16-23).
    case visualizerData = 16

    /// The artwork channel index (0-3) for artwork message types, or `nil` for non-artwork types.
    var artworkChannel: Int? {
        switch self {
        case .artworkChannel0, .artworkChannel1, .artworkChannel2, .artworkChannel3:
            Int(rawValue - BinaryMessageType.artworkChannel0.rawValue)
        default:
            nil
        }
    }
}

/// Binary message from server.
struct BinaryMessage: Sendable {
    /// Size of the binary header: 1 byte type + 8 bytes timestamp.
    static let headerSize: Int = 9

    /// Message type.
    let type: BinaryMessageType
    /// Server timestamp in microseconds when this should be played/displayed.
    let timestamp: Int64
    /// Message payload (audio data, image data, etc.).
    let data: Data

    /// Decode binary message from WebSocket data.
    /// - Parameter data: Raw WebSocket binary frame.
    init?(data: Data) {
        guard data.count >= Self.headerSize else {
            return nil
        }

        let typeValue = data[0]
        guard let type = BinaryMessageType(rawValue: typeValue) else {
            return nil
        }

        self.type = type

        // Extract big-endian int64 from bytes 1..<headerSize.
        // Uses loadUnaligned because Data slices aren't guaranteed to be aligned.
        let extractedTimestamp = data[1 ..< Self.headerSize].withUnsafeBytes { buffer in
            buffer.loadUnaligned(as: Int64.self).bigEndian
        }

        // Server timestamps are monotonic clock microseconds — negative is nonsensical.
        guard extractedTimestamp >= 0 else {
            return nil
        }

        timestamp = extractedTimestamp
        // subdata(in:) copies the payload into a fresh Data with startIndex == 0.
        // Data slicing (data[headerSize...]) would be zero-copy but produces a non-zero
        // startIndex, which breaks downstream code that indexes from 0.
        self.data = data.subdata(in: Self.headerSize ..< data.count)
    }
}
