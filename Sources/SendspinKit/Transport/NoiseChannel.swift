import Foundation

/// Message-type bytes owned by the framing layer itself. Role message types
/// (4+ audio, 8–11 artwork, 16–23 visualizer) live in `BinaryMessageType`.
enum NoiseFrameType {
    /// A JSON message body (UTF-8) — the encrypted form of every control message.
    static let json: UInt8 = 0
    /// A fragmentation envelope. Its flags and optional original type follow this byte.
    static let fragment: UInt8 = 1
}

/// Flags carried in the type-1 fragmentation envelope.
enum NoiseFragmentFlags {
    static let none: UInt8 = 0
    static let last: UInt8 = 1 << 0
    static let first: UInt8 = 1 << 1
    static let reservedMask: UInt8 = 0b1111_1100
}

/// The encrypted framing layer between the WebSocket and the message loop: every
/// frame is a Noise ciphertext whose plaintext is `[type byte][payload]`, with
/// type-1 envelopes splitting and reassembling anything over the
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
    /// 65518. A first fragment spends one byte each on flags and `orig_type`.
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
        guard firstByte != NoiseFrameType.fragment else {
            // A fragment type can never be an orig_type; refusing at the sender
            // keeps a local bug from becoming a peer-visible protocol error.
            throw NoiseError.fragmentationViolation
        }

        if message.count <= Self.maxPlaintext {
            return try [transport.send.encrypt(associatedData: Data(), plaintext: message)]
        }

        var frames: [Data] = []
        var remaining = message.dropFirst()

        // First fragment: [1][first flag][orig_type][data].
        let firstChunk = remaining.prefix(Self.maxPlaintext - 3)
        var opening = Data([NoiseFrameType.fragment, NoiseFragmentFlags.first, firstByte])
        opening.append(contentsOf: firstChunk)
        try frames.append(transport.send.encrypt(associatedData: Data(), plaintext: opening))
        remaining = remaining.dropFirst(firstChunk.count)

        // Continuation fragments: [1][flags][data]. Keep the final fragment
        // separate so it carries the last flag.
        while remaining.count > Self.maxPlaintext - 2 {
            let chunk = remaining.prefix(Self.maxPlaintext - 2)
            var frame = Data([NoiseFrameType.fragment, NoiseFragmentFlags.none])
            frame.append(contentsOf: chunk)
            try frames.append(transport.send.encrypt(associatedData: Data(), plaintext: frame))
            remaining = remaining.dropFirst(chunk.count)
        }

        // Final fragment: [1][last flag][data].
        var closing = Data([NoiseFrameType.fragment, NoiseFragmentFlags.last])
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

        guard frameType == NoiseFrameType.fragment else {
            guard reassembly == nil else { throw NoiseError.fragmentationViolation }
            return plaintext
        }

        guard let flags = body.first, flags & NoiseFragmentFlags.reservedMask == 0 else {
            throw NoiseError.fragmentationViolation
        }
        let isFirst = flags & NoiseFragmentFlags.first != 0
        let isLast = flags & NoiseFragmentFlags.last != 0

        if isFirst {
            guard reassembly == nil else { throw NoiseError.fragmentationViolation }
            guard let origType = body.dropFirst().first,
                  origType != NoiseFrameType.fragment
            else { throw NoiseError.fragmentationViolation }

            reassembly = (origType, Data(body.dropFirst(2)))
            if isLast {
                let completed = reassembly!
                reassembly = nil
                var message = Data([completed.origType])
                message.append(completed.buffer)
                return message
            }
            return nil
        }

        guard reassembly != nil else { throw NoiseError.fragmentationViolation }
        try appendToReassembly(body.dropFirst())
        guard isLast else { return nil }

        let completed = reassembly!
        reassembly = nil
        var message = Data([completed.origType])
        message.append(completed.buffer)
        return message
    }

    private mutating func appendToReassembly(_ data: Data.SubSequence) throws {
        guard reassembly!.buffer.count + data.count <= Self.maxReassembledSize else {
            reassembly = nil
            throw NoiseError.reassemblyLimitExceeded
        }
        reassembly!.buffer.append(contentsOf: data)
    }
}
