import CryptoKit
import Foundation
@testable import SendspinKit
import Testing

/// Both sides of a completed KKpsk2 handshake. The server side is exposed both as a
/// channel (conformant peer) and — via `makeRawPair` — as raw transport cipher
/// states, letting tests hand-craft protocol-violating frames a conformant sender
/// refuses to build.
private func makeTransportPair(
    suite: NoiseCipherSuite = .chaChaPoly
) throws -> (server: NoiseTransport, client: NoiseTransport) {
    let serverStatic = Curve25519.KeyAgreement.PrivateKey()
    let clientStatic = Curve25519.KeyAgreement.PrivateKey()
    let psk = Psk.generate()
    var server = NoiseHandshake(
        suite: suite,
        role: .initiator,
        localStaticKey: serverStatic,
        remoteStaticPublicKey: clientStatic.publicKey,
        prologue: Data()
    )
    var client = NoiseHandshake(
        suite: suite,
        role: .responder,
        localStaticKey: clientStatic,
        remoteStaticPublicKey: serverStatic.publicKey,
        prologue: Data()
    )
    _ = try client.readMessage1(server.writeMessage1(payload: Data("{}".utf8)))
    _ = try server.readMessage2(client.writeMessage2(psk: psk, payload: Data("{}".utf8)), psk: psk)
    return try (server.makeTransport(), client.makeTransport())
}

/// Struct wrapper because noncopyable values cannot ride in tuples.
private struct ChannelPair: ~Copyable {
    var server: NoiseChannel
    var client: NoiseChannel
}

private func makeChannelPair(
    suite: NoiseCipherSuite = .chaChaPoly
) throws -> ChannelPair {
    let (server, client) = try makeTransportPair(suite: suite)
    return ChannelPair(
        server: NoiseChannel(transport: server),
        client: NoiseChannel(transport: client)
    )
}

/// Deliver every frame of an encrypted message; exactly the last one must complete.
private func deliver(_ frames: [Data], to receiver: inout NoiseChannel) throws -> Data {
    for frame in frames.dropLast() {
        #expect(try receiver.decryptFrame(frame) == nil)
    }
    let message = try receiver.decryptFrame(frames.last!)
    return try #require(message)
}

@Suite("Noise channel framing", .timeLimit(.minutes(1)))
struct NoiseChannelTests {
    @Test("Small message travels as a single frame and round-trips")
    func smallMessageSingleFrame() throws {
        var pair = try makeChannelPair()
        var message = Data([NoiseFrameType.json])
        message.append(Data("{\"type\":\"server/hello\"}".utf8))
        let frames = try pair.server.encryptMessage(message)
        #expect(frames.count == 1)
        #expect(try deliver(frames, to: &pair.client) == message)
    }

    @Test("Largest single-frame message stays unfragmented; one byte more fragments")
    func fragmentationBoundary() throws {
        var pair = try makeChannelPair()

        var atLimit = Data([NoiseFrameType.json])
        atLimit.append(Data(repeating: 0xAB, count: NoiseChannel.maxSinglePayload))
        let single = try pair.server.encryptMessage(atLimit)
        #expect(single.count == 1)
        #expect(single[0].count == NoiseChannel.maxNoiseMessage)
        #expect(try deliver(single, to: &pair.client) == atLimit)

        var overLimit = Data([NoiseFrameType.json])
        overLimit.append(Data(repeating: 0xCD, count: NoiseChannel.maxSinglePayload + 1))
        let fragmented = try pair.server.encryptMessage(overLimit)
        #expect(fragmented.count == 2)
        for frame in fragmented {
            #expect(frame.count <= NoiseChannel.maxNoiseMessage)
        }
        #expect(try deliver(fragmented, to: &pair.client) == overLimit)
    }

    @Test("Multi-frame fragmentation reassembles a large message byte-exactly")
    func largeMessageReassembles() throws {
        var pair = try makeChannelPair()
        // Non-uniform payload so misordered reassembly cannot accidentally pass.
        var payload = Data(capacity: 200_000)
        for index in 0 ..< 200_000 {
            payload.append(UInt8(truncatingIfNeeded: index &* 31 &+ (index >> 8)))
        }
        var message = Data([BinaryMessageType.artworkChannel0.rawValue])
        message.append(payload)
        let frames = try pair.server.encryptMessage(message)
        #expect(frames.count == 4) // 200_000 payload bytes: 65517 + 65518 + 65518 + remainder
        #expect(try deliver(frames, to: &pair.client) == message)
    }

    @Test("Fragment-end with no message in flight closes the connection")
    func fragmentEndWithoutInFlight() throws {
        var (rogueServer, clientTransport) = try makeTransportPair()
        var client = NoiseChannel(transport: clientTransport)
        let rogue = try rogueServer.send.encrypt(
            associatedData: Data(),
            plaintext: Data([NoiseFrameType.fragmentEnd, 0x00])
        )
        #expect(throws: NoiseError.fragmentationViolation) {
            _ = try client.decryptFrame(rogue)
        }
    }

    @Test("Non-fragment frame during reassembly closes the connection")
    func interleavedNonFragmentFrame() throws {
        var (rogueServer, clientTransport) = try makeTransportPair()
        var client = NoiseChannel(transport: clientTransport)
        let opening = try rogueServer.send.encrypt(
            associatedData: Data(),
            plaintext: Data([NoiseFrameType.fragmentMore, NoiseFrameType.json, 0x01])
        )
        #expect(try client.decryptFrame(opening) == nil)
        let interloper = try rogueServer.send.encrypt(
            associatedData: Data(),
            plaintext: Data([NoiseFrameType.json, 0x02])
        )
        #expect(throws: NoiseError.fragmentationViolation) {
            _ = try client.decryptFrame(interloper)
        }
    }

    @Test("A fragment type as orig_type is rejected on both sides")
    func fragmentTypeAsOrigType() throws {
        var (rogueServer, clientTransport) = try makeTransportPair()
        var client = NoiseChannel(transport: clientTransport)
        var sender = NoiseChannel(transport: rogueServer)

        // Sender refuses to build such a message at all.
        var oversized = Data([NoiseFrameType.fragmentEnd])
        oversized.append(Data(count: NoiseChannel.maxPlaintext))
        #expect(throws: NoiseError.fragmentationViolation) {
            _ = try sender.encryptMessage(oversized)
        }
        // Receiver treats it as a protocol error.
        let rogue = try rogueServer.send.encrypt(
            associatedData: Data(),
            plaintext: Data([NoiseFrameType.fragmentMore, NoiseFrameType.fragmentMore, 0x00])
        )
        #expect(throws: NoiseError.fragmentationViolation) {
            _ = try client.decryptFrame(rogue)
        }
    }

    @Test("Reassembly past the cap is rejected instead of buffering unbounded data")
    func reassemblyCap() throws {
        var (rogueServer, clientTransport) = try makeTransportPair()
        var client = NoiseChannel(transport: clientTransport)
        let opening = try rogueServer.send.encrypt(
            associatedData: Data(),
            plaintext: Data([NoiseFrameType.fragmentMore, NoiseFrameType.json])
        )
        #expect(try client.decryptFrame(opening) == nil)
        // Continuation chunks large enough to cross the cap in a bounded loop.
        var continuation = Data([NoiseFrameType.fragmentMore])
        continuation.append(Data(repeating: 0xEE, count: NoiseChannel.maxSinglePayload))
        var delivered = 0
        var caught = false
        while delivered <= NoiseChannel.maxReassembledSize {
            let frame = try rogueServer.send.encrypt(associatedData: Data(), plaintext: continuation)
            do {
                _ = try client.decryptFrame(frame)
                delivered += NoiseChannel.maxSinglePayload
            } catch let error as NoiseError {
                #expect(error == .reassemblyLimitExceeded)
                caught = true
                break
            }
        }
        #expect(caught, "the cap never triggered")
    }

    @Test("Rekey swaps to the new session keys in both directions")
    func rekeySwapsKeys() throws {
        var pair = try makeChannelPair()
        let firstHash = pair.client.handshakeHash

        // Run a re-handshake keyed off the prior h, as the spec's re-handshake does.
        let serverStatic = Curve25519.KeyAgreement.PrivateKey()
        let clientStatic = Curve25519.KeyAgreement.PrivateKey()
        let newPsk = Psk.generate()
        var serverHandshake = NoiseHandshake(
            suite: .chaChaPoly,
            role: .initiator,
            localStaticKey: serverStatic,
            remoteStaticPublicKey: clientStatic.publicKey,
            prologue: firstHash
        )
        var clientHandshake = NoiseHandshake(
            suite: .chaChaPoly,
            role: .responder,
            localStaticKey: clientStatic,
            remoteStaticPublicKey: serverStatic.publicKey,
            prologue: firstHash
        )
        _ = try clientHandshake.readMessage1(serverHandshake.writeMessage1(payload: Data("{}".utf8)))
        _ = try serverHandshake.readMessage2(
            clientHandshake.writeMessage2(psk: newPsk, payload: Data("{}".utf8)),
            psk: newPsk
        )

        // A frame encrypted under the old keys, delivered after the receiver rekeys,
        // must fail — the swap is a hard boundary. A failed decrypt does not consume
        // a nonce, so the same channel keeps working afterwards.
        let staleFrame = try pair.server.encryptMessage(Data([NoiseFrameType.json, 0x01]))[0]
        try pair.client.rekey(to: clientHandshake.makeTransport())
        try pair.server.rekey(to: serverHandshake.makeTransport())
        #expect(throws: NoiseError.decryptFailed) {
            _ = try pair.client.decryptFrame(staleFrame)
        }
        #expect(pair.client.handshakeHash != firstHash)

        // Fresh traffic flows under the new keys in both directions.
        var message = Data([NoiseFrameType.json])
        message.append(Data("rekeyed".utf8))
        #expect(try deliver(pair.server.encryptMessage(message), to: &pair.client) == message)
        #expect(try deliver(pair.client.encryptMessage(message), to: &pair.server) == message)
    }
}
