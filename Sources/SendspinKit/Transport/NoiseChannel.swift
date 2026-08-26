import Foundation

/// Message-type bytes owned by the framing layer itself. Role message types
/// (4+ audio, 8–11 artwork, 16–23 visualizer) live in `BinaryMessageType`.
enum NoiseFrameType {
    /// A JSON message body (UTF-8) — the encrypted form of every control message.
    static let json: UInt8 = 0
    /// A fragment with more to follow. The first fragment of a message additionally
    /// carries the original type byte after this one.
    static let fragmentMore: UInt8 = 2
    /// The final fragment of a fragmented message.
    static let fragmentEnd: UInt8 = 3
}

/// The encrypted framing layer between the WebSocket and the message loop: every
/// frame is a Noise ciphertext whose plaintext is `[type byte][payload]`, with
/// fragment frames (types 2/3) splitting and reassembling anything over the
/// single-message budget.
///
/// Noncopyable because the cipher states carry AEAD nonce counters: two live copies
/// would encrypt under the same (key, nonce). The compiler enforces the single
/// ownership the nonce safety requires.
struct NoiseChannel: ~Copyable {
    /// Noise's hard ceiling for one transport message, including the AEAD tag.
    static let maxNoiseMessage = 65_535
    /// Max AEAD plaintext per frame: the Noise ceiling minus the 16-byte tag.
    /// This budget covers the type byte plus payload.
    static let maxPlaintext = maxNoiseMessage - NoiseCipherSuite.tagLength
    /// Max payload bytes after the type byte in a non-fragmented frame — the spec's
    /// 65518. A first fragment spends one more byte on `orig_type`.
    static let maxSinglePayload = maxPlaintext - 1
    /// Reassembly cap: an implementation-defined DoS guard (not spec), sized far
    /// above the largest legitimate message (full-resolution artwork).
    static let maxReassembledSize = 16 * 1_024 * 1_024

    private var transport: NoiseTransport
    private var reassembly: (origType: UInt8, buffer: Data)?

    init(transport: NoiseTransport) {
        self.transport = transport
    }

    /// The handshake hash `h` of the session keys currently in use — the prologue
    /// of a future re-handshake.
    var handshakeHash: Data {
        transport.handshakeHash
    }

    /// Swap in the session keys produced by a re-handshake. The caller controls
    /// ordering: the re-handshake's final message goes out under the old keys, and
    /// every frame after this call uses the new ones.
    mutating func rekey(to newTransport: NoiseTransport) {
        transport = newTransport
    }

    /// Encrypt one plaintext message (`[type byte][payload]`) into one or more wire
    /// frames, fragmenting when it exceeds the single-frame budget.
    ///
    /// Caller contract: send every returned frame, in order, with nothing interleaved
    /// in the same direction — a fragmented message must finish before any other
    /// frame (spec Fragmentation). A partial send is terminal for the connection.
    mutating func encryptMessage(_ message: Data) throws -> [Data] {
        guard let firstByte = message.first else { throw NoiseError.malformedMessage }
        guard firstByte != NoiseFrameType.fragmentMore, firstByte != NoiseFrameType.fragmentEnd else {
            // A fragment type can never be an orig_type; refusing at the sender
            // keeps a local bug from becoming a peer-visible protocol error.
            throw NoiseError.fragmentationViolation
        }

        if message.count <= Self.maxPlaintext {
            return try [transport.send.encrypt(associatedData: Data(), plaintext: message)]
        }

        var frames: [Data] = []
        var remaining = message.dropFirst()

        // Opening fragment-more frame: [2][orig_type][data].
        let firstChunk = remaining.prefix(Self.maxPlaintext - 2)
        var opening = Data([NoiseFrameType.fragmentMore, firstByte])
        opening.append(contentsOf: firstChunk)
        try frames.append(transport.send.encrypt(associatedData: Data(), plaintext: opening))
        remaining = remaining.dropFirst(firstChunk.count)

        // Continuation fragment-more frames: [2][data].
        while remaining.count > Self.maxSinglePayload {
            let chunk = remaining.prefix(Self.maxSinglePayload)
            var frame = Data([NoiseFrameType.fragmentMore])
            frame.append(contentsOf: chunk)
            try frames.append(transport.send.encrypt(associatedData: Data(), plaintext: frame))
            remaining = remaining.dropFirst(chunk.count)
        }

        // Closing fragment-end frame: [3][data].
        var closing = Data([NoiseFrameType.fragmentEnd])
        closing.append(contentsOf: remaining)
        try frames.append(transport.send.encrypt(associatedData: Data(), plaintext: closing))
        return frames
    }

    /// Decrypt one wire frame. Returns the complete plaintext message
    /// (`[type byte][payload]`) or `nil` while a fragmented message is still being
    /// reassembled. Every thrown error is terminal for the connection.
    mutating func decryptFrame(_ frame: Data) throws -> Data? {
        let plaintext = try transport.receive.decrypt(associatedData: Data(), ciphertext: frame)
        guard let frameType = plaintext.first else { throw NoiseError.malformedMessage }
        let body = plaintext.dropFirst()

        switch frameType {
        case NoiseFrameType.fragmentMore:
            if reassembly == nil {
                // Opening frame carries orig_type before the data.
                guard let origType = body.first else { throw NoiseError.malformedMessage }
                guard origType != NoiseFrameType.fragmentMore,
                      origType != NoiseFrameType.fragmentEnd
                else { throw NoiseError.fragmentationViolation }
                reassembly = (origType, Data(body.dropFirst()))
            } else {
                try appendToReassembly(body)
            }
            return nil

        case NoiseFrameType.fragmentEnd:
            guard reassembly != nil else { throw NoiseError.fragmentationViolation }
            try appendToReassembly(body)
            let completed = reassembly!
            reassembly = nil
            var message = Data([completed.origType])
            message.append(completed.buffer)
            return message

        default:
            guard reassembly == nil else { throw NoiseError.fragmentationViolation }
            return plaintext
        }
    }

    private mutating func appendToReassembly(_ data: Data.SubSequence) throws {
        guard reassembly!.buffer.count + data.count <= Self.maxReassembledSize else {
            reassembly = nil
            throw NoiseError.reassemblyLimitExceeded
        }
        reassembly!.buffer.append(contentsOf: data)
    }
}
