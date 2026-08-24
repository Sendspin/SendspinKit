import CryptoKit
import Foundation
@testable import SendspinKit
import Testing

/// A connected initiator/responder pair with fresh static keys, mirroring the wire
/// roles: the server is the Noise initiator, the client the responder.
private struct HandshakePair {
    var server: NoiseHandshake
    var client: NoiseHandshake
    let serverStatic: Curve25519.KeyAgreement.PrivateKey
    let clientStatic: Curve25519.KeyAgreement.PrivateKey

    init(
        suite: NoiseCipherSuite,
        serverPrologue: Data = Data("prologue".utf8),
        clientPrologue: Data = Data("prologue".utf8)
    ) {
        serverStatic = Curve25519.KeyAgreement.PrivateKey()
        clientStatic = Curve25519.KeyAgreement.PrivateKey()
        server = NoiseHandshake(
            suite: suite,
            role: .initiator,
            localStaticKey: serverStatic,
            remoteStaticPublicKey: clientStatic.publicKey,
            prologue: serverPrologue
        )
        client = NoiseHandshake(
            suite: suite,
            role: .responder,
            localStaticKey: clientStatic,
            remoteStaticPublicKey: serverStatic.publicKey,
            prologue: clientPrologue
        )
    }
}

@Suite("Noise KKpsk2 handshake")
struct NoiseHandshakeTests {
    @Test("Full round trip into transport mode", arguments: NoiseCipherSuite.allCases)
    func roundTrip(suite: NoiseCipherSuite) throws {
        var pair = HandshakePair(suite: suite)
        let psk = Psk.generate()

        let message1 = try pair.server.writeMessage1(payload: Data("{\"psk_id\":\"x\"}".utf8))
        let payload1 = try pair.client.readMessage1(message1)
        #expect(payload1 == Data("{\"psk_id\":\"x\"}".utf8))

        let message2 = try pair.client.writeMessage2(psk: psk, payload: Data("{}".utf8))
        let payload2 = try pair.server.readMessage2(message2, psk: psk)
        #expect(payload2 == Data("{}".utf8))

        // Both sides agree on the final transcript hash.
        #expect(pair.server.handshakeHash == pair.client.handshakeHash)

        var serverTransport = try pair.server.makeTransport()
        var clientTransport = try pair.client.makeTransport()
        #expect(serverTransport.handshakeHash == clientTransport.handshakeHash)

        // Traffic flows both ways under the split keys.
        let toClient = try serverTransport.send.encrypt(associatedData: Data(), plaintext: Data("hello".utf8))
        #expect(toClient != Data("hello".utf8))
        #expect(try clientTransport.receive.decrypt(associatedData: Data(), ciphertext: toClient) == Data("hello".utf8))
        let toServer = try clientTransport.send.encrypt(associatedData: Data(), plaintext: Data("world".utf8))
        #expect(try serverTransport.receive.decrypt(associatedData: Data(), ciphertext: toServer) == Data("world".utf8))
    }

    @Test("Message 1 is readable before any PSK is chosen (deferred psk2 selection)")
    func message1NeedsNoPsk() throws {
        var pair = HandshakePair(suite: .chaChaPoly)
        let message1 = try pair.server.writeMessage1(payload: Data("{\"psk_id\":\"abc\"}".utf8))
        // The responder decrypts message 1 having supplied no PSK anywhere; only
        // writeMessage2 takes one. Successful decryption is the property itself.
        let payload = try pair.client.readMessage1(message1)
        #expect(payload == Data("{\"psk_id\":\"abc\"}".utf8))
    }

    @Test("PSK mismatch fails at message 2, not earlier")
    func pskMismatchFailsAtMessage2() throws {
        var pair = HandshakePair(suite: .chaChaPoly)
        _ = try pair.client.readMessage1(pair.server.writeMessage1(payload: Data("{}".utf8)))
        let message2 = try pair.client.writeMessage2(psk: Psk.generate(), payload: Data("{}".utf8))
        #expect(throws: NoiseError.decryptFailed) {
            var server = pair.server
            _ = try server.readMessage2(message2, psk: Psk.generate())
        }
    }

    @Test("Prologue mismatch fails the handshake")
    func prologueMismatchFails() throws {
        var pair = HandshakePair(
            suite: .chaChaPoly,
            serverPrologue: Data("client-init||server-init".utf8),
            clientPrologue: Data("client-init||tampered".utf8)
        )
        let message1 = try pair.server.writeMessage1(payload: Data("{}".utf8))
        #expect(throws: NoiseError.decryptFailed) {
            _ = try pair.client.readMessage1(message1)
        }
    }

    @Test("Wrong responder static key fails message 1 (KK mutual authentication)")
    func wrongStaticFails() throws {
        var pair = HandshakePair(suite: .chaChaPoly)
        // An imposter client with a different static key than the one the server
        // pre-knows cannot decrypt message 1.
        var imposter = NoiseHandshake(
            suite: .chaChaPoly,
            role: .responder,
            localStaticKey: Curve25519.KeyAgreement.PrivateKey(),
            remoteStaticPublicKey: pair.serverStatic.publicKey,
            prologue: Data("prologue".utf8)
        )
        let message1 = try pair.server.writeMessage1(payload: Data("{}".utf8))
        #expect(throws: NoiseError.decryptFailed) {
            _ = try imposter.readMessage1(message1)
        }
    }

    @Test("Tampered transport ciphertext fails and poisons nothing else")
    func tamperedTransportFails() throws {
        var (server, client) = try establishedTransports(suite: .chaChaPoly)
        var frame = try server.send.encrypt(associatedData: Data(), plaintext: Data("audio".utf8))
        frame[frame.startIndex] ^= 0x01
        #expect(throws: NoiseError.decryptFailed) {
            _ = try client.receive.decrypt(associatedData: Data(), ciphertext: frame)
        }
    }

    @Test("Replayed and reordered transport frames fail AEAD (counter protection)")
    func replayAndReorderFail() throws {
        var (server, client) = try establishedTransports(suite: .chaChaPoly)
        let first = try server.send.encrypt(associatedData: Data(), plaintext: Data("one".utf8))
        let second = try server.send.encrypt(associatedData: Data(), plaintext: Data("two".utf8))

        // Reorder: delivering the second frame first fails.
        var reordered = client
        #expect(throws: NoiseError.decryptFailed) {
            _ = try reordered.receive.decrypt(associatedData: Data(), ciphertext: second)
        }

        // Replay: delivering the first frame twice fails on the second delivery.
        _ = try client.receive.decrypt(associatedData: Data(), ciphertext: first)
        #expect(throws: NoiseError.decryptFailed) {
            _ = try client.receive.decrypt(associatedData: Data(), ciphertext: first)
        }
    }

    @Test("Transport can be issued exactly once (duplicate would reuse nonces)")
    func transportIssuedOnce() throws {
        var pair = HandshakePair(suite: .chaChaPoly)
        let psk = Psk.generate()
        _ = try pair.client.readMessage1(pair.server.writeMessage1(payload: Data("{}".utf8)))
        _ = try pair.server.readMessage2(
            pair.client.writeMessage2(psk: psk, payload: Data("{}".utf8)),
            psk: psk
        )
        _ = try pair.client.makeTransport()
        #expect(throws: NoiseError.invalidState) {
            _ = try pair.client.makeTransport()
        }
    }

    @Test("Exhausted nonce counter refuses further traffic instead of wrapping")
    func nonceExhaustion() throws {
        let key = SymmetricKey(size: .bits256)
        var sender = NoiseCipherState(suite: .chaChaPoly, key: key, counter: .max)
        #expect(throws: NoiseError.nonceExhausted) {
            _ = try sender.encrypt(associatedData: Data(), plaintext: Data("x".utf8))
        }
        var receiver = NoiseCipherState(suite: .chaChaPoly, key: key, counter: .max)
        #expect(throws: NoiseError.nonceExhausted) {
            _ = try receiver.decrypt(associatedData: Data(), ciphertext: Data(count: 17))
        }
    }

    @Test("Out-of-order handshake calls are invalid state")
    func stateMachineGuards() throws {
        var pair = HandshakePair(suite: .chaChaPoly)
        // Responder cannot write message 2 before reading message 1.
        #expect(throws: NoiseError.invalidState) {
            var client = pair.client
            _ = try client.writeMessage2(psk: .sentinel, payload: Data())
        }
        // Initiator cannot read message 1 (it writes it), and cannot split early.
        #expect(throws: NoiseError.invalidState) {
            var server = pair.server
            _ = try server.readMessage1(Data(count: 64))
        }
        #expect(throws: NoiseError.invalidState) {
            _ = try pair.server.makeTransport()
        }
        // Truncated message 1 is malformed, not a crash.
        _ = try pair.server.writeMessage1(payload: Data())
        #expect(throws: NoiseError.malformedMessage) {
            var client = pair.client
            _ = try client.readMessage1(Data(count: 31))
        }
    }

    /// Drive a fresh pair to transport mode.
    private func establishedTransports(
        suite: NoiseCipherSuite
    ) throws -> (server: NoiseTransport, client: NoiseTransport) {
        var pair = HandshakePair(suite: suite)
        let psk = Psk.generate()
        _ = try pair.client.readMessage1(pair.server.writeMessage1(payload: Data("{}".utf8)))
        _ = try pair.server.readMessage2(
            pair.client.writeMessage2(psk: psk, payload: Data("{}".utf8)),
            psk: psk
        )
        return try (pair.server.makeTransport(), pair.client.makeTransport())
    }
}
