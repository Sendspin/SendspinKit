import Foundation
import os

/// Binary message type ID allocation per Sendspin spec:
/// - 0: JSON, 1: fragmentation, 2: pairing digit audio clip, 3: reserved
/// - 4-7: Player role (audio chunks)
/// - 8-11: Artwork role (channels 0-3)
/// - 16-23: Visualizer role
/// - 24-191: Reserved for future roles
/// - 192-255: Application-specific roles
enum BinaryMessageType: UInt8 {
    /// Pairing digit audio clip.
    case digitAudioClip = 2

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

/// The strict transfer state for the artwork role's announce/part protocol.
struct ArtworkTransfer: Sendable {
    let channel: Int
    let timestamp: Int64
    let totalSize: UInt32
    let deliver: Bool
    var received: UInt32 = 0
    var data = Data()

    mutating func append(_ bytes: Data) throws -> ArtworkTransferResult? {
        let count = UInt32(bytes.count)
        guard count <= totalSize - received else { throw ArtworkTransferError.partPastTotalSize }
        received += count
        if deliver {
            data.append(bytes)
        }
        guard received == totalSize else {
            return nil
        }
        return ArtworkTransferResult(channel: channel, timestamp: timestamp, data: deliver ? data : Data(), deliver: deliver)
    }
}

struct ArtworkTransferResult: Sendable {
    let channel: Int
    let timestamp: Int64
    let data: Data
    let deliver: Bool
}

struct ScheduledArtwork: Sendable {
    let artwork: ArtworkData
    let localDisplayTime: Int64
}

struct ScheduledMetadata: Sendable {
    let metadata: TrackMetadata
    let localDisplayTime: Int64
}

struct ScheduledColor: Sendable {
    let color: ColorState
    let localDisplayTime: Int64
}

enum ArtworkTransferError: Error, Equatable {
    case tooShort
    case invalidMessageType
    case tooLarge
    case reservedFlags
    case bothAnnounceAndCancel
    case announceWrongLength
    case announceWhileInFlight
    case cancelWrongLength
    case partWithoutTransfer
    case partWrongChannel
    case partPastTotalSize
}

/// Strictly classify one artwork wire message and update a transfer state.
/// The caller owns stream/state gates; rejected transfers still advance counts.
struct ArtworkWireMessage {
    static let maxMessageSize = 65_519
    static let announceLength = 14
    static let announceFlag: UInt8 = 0b10
    static let cancelFlag: UInt8 = 0b01
    static let reservedMask: UInt8 = 0b1111_1100

    let channel: Int
    let flags: UInt8
    let timestamp: Int64?
    let totalSize: UInt32?
    let data: Data

    init(data raw: Data) throws {
        guard raw.count >= 2 else { throw ArtworkTransferError.tooShort }
        guard raw.count <= Self.maxMessageSize else { throw ArtworkTransferError.tooLarge }
        guard let type = BinaryMessageType(rawValue: raw[0]), let channel = type.artworkChannel else {
            throw ArtworkTransferError.invalidMessageType
        }
        let flags = raw[1]
        guard flags & Self.reservedMask == 0 else { throw ArtworkTransferError.reservedFlags }
        guard flags & Self.announceFlag == 0 || flags & Self.cancelFlag == 0 else {
            throw ArtworkTransferError.bothAnnounceAndCancel
        }
        self.channel = channel
        self.flags = flags
        if flags & Self.announceFlag != 0 {
            guard raw.count == Self.announceLength else { throw ArtworkTransferError.announceWrongLength }
            timestamp = raw[2 ..< 10].withUnsafeBytes { $0.loadUnaligned(as: Int64.self).bigEndian }
            totalSize = raw[10 ..< 14].withUnsafeBytes { $0.loadUnaligned(as: UInt32.self).bigEndian }
            data = Data()
        } else if flags & Self.cancelFlag != 0 {
            guard raw.count == 2 else { throw ArtworkTransferError.cancelWrongLength }
            timestamp = nil
            totalSize = nil
            data = Data()
        } else {
            timestamp = nil
            totalSize = nil
            data = raw.dropFirst(2)
        }
    }

    var isAnnounce: Bool {
        flags & Self.announceFlag != 0
    }

    var isCancel: Bool {
        flags & Self.cancelFlag != 0
    }
}

/// Binary message from server.
struct BinaryMessage {
    /// Live visualizer message layout: one type byte followed by an eight-byte timestamp.
    static let headerSize: Int = 9
    /// Player audio header size: type, timestamp, and send_ahead.
    static let audioChunkHeaderSize: Int = 13

    /// Message type.
    let type: BinaryMessageType
    /// Server timestamp in microseconds when this should be played/displayed.
    /// Types without a timestamp use zero.
    let timestamp: Int64
    /// Lead time reported by a player chunk in microseconds. This is measurement-only and
    /// never participates in scheduling.
    let sendAhead: UInt32
    /// Digit selector for a pairing audio clip; nil for other message types.
    let digit: UInt8?
    /// Message payload (audio data, image data, digit clip, or role-specific raw bytes).
    let data: Data

    /// Decode binary message from WebSocket data using the layout assigned to its type.
    init?(data: Data) {
        guard let typeValue = data.first,
              let type = BinaryMessageType(rawValue: typeValue)
        else {
            if let typeValue = data.first {
                Log.client.warning("Unrecognized binary message type ID: \(typeValue)")
            }
            return nil
        }

        self.type = type
        switch type {
        case .audioChunk:
            digit = nil
            guard data.count >= Self.audioChunkHeaderSize else { return nil }
            let extractedTimestamp = Self.readInt64(data, offset: 1)
            guard extractedTimestamp >= 0 else { return nil }
            timestamp = extractedTimestamp
            sendAhead = Self.readUInt32(data, offset: 9)
            self.data = data.subdata(in: Self.audioChunkHeaderSize ..< data.count)

        case .digitAudioClip:
            // Phase 3 pairing state machine owns digit range validation (0-9).
            guard data.count >= 2 else { return nil }
            timestamp = 0
            sendAhead = 0
            digit = data[1]
            self.data = data.subdata(in: 2 ..< data.count)

        case .artworkChannel0, .artworkChannel1, .artworkChannel2, .artworkChannel3:
            // Artwork announce/part/cancel decoding owns every byte after the type.
            timestamp = 0
            sendAhead = 0
            digit = nil
            self.data = data.subdata(in: 1 ..< data.count)

        case .visualizerData:
            digit = nil
            guard data.count >= Self.headerSize else { return nil }
            let extractedTimestamp = Self.readInt64(data, offset: 1)
            guard extractedTimestamp >= 0 else { return nil }
            timestamp = extractedTimestamp
            sendAhead = 0
            self.data = data.subdata(in: Self.headerSize ..< data.count)
        }
    }

    private static func readInt64(_ data: Data, offset: Int) -> Int64 {
        data[offset ..< offset + MemoryLayout<Int64>.size].withUnsafeBytes { buffer in
            buffer.loadUnaligned(as: Int64.self).bigEndian
        }
    }

    private static func readUInt32(_ data: Data, offset: Int) -> UInt32 {
        data[offset ..< offset + MemoryLayout<UInt32>.size].withUnsafeBytes { buffer in
            buffer.loadUnaligned(as: UInt32.self).bigEndian
        }
    }
}
