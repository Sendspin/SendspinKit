import CryptoKit
import Foundation
@testable import SendspinKit
import Testing

/// Known-answer tests against the cacophony project's published Noise test vectors
/// (the same corpus snow and other Noise implementations validate against). These
/// are the independent check that our KKpsk2 state machine is interoperable — a
/// Swift-initiator/Swift-responder round trip alone could hide a shared bug.
private struct VectorFile: Decodable {
    let vectors: [Vector]
}

private struct Vector: Decodable {
    let protocolName: String
    let initPrologue: String
    let initPsks: [String]
    let initStatic: String
    let initEphemeral: String
    let respPrologue: String
    let respStatic: String
    let respEphemeral: String
    let handshakeHash: String
    let messages: [VectorMessage]

    enum CodingKeys: String, CodingKey {
        case protocolName = "protocol_name"
        case initPrologue = "init_prologue"
        case initPsks = "init_psks"
        case initStatic = "init_static"
        case initEphemeral = "init_ephemeral"
        case respPrologue = "resp_prologue"
        case respStatic = "resp_static"
        case respEphemeral = "resp_ephemeral"
        case handshakeHash = "handshake_hash"
        case messages
    }
}

private struct VectorMessage: Decodable {
    let payload: String
    let ciphertext: String
}

@Suite("Noise KKpsk2 known-answer vectors")
struct NoiseVectorTests {
    private static func loadVectors() throws -> [Vector] {
        let url = try #require(Bundle.module.url(
            forResource: "kkpsk2-cacophony-vectors",
            withExtension: "json",
            subdirectory: "Resources"
        ))
        return try JSONDecoder().decode(VectorFile.self, from: Data(contentsOf: url)).vectors
    }

    private static func suite(for vector: Vector) throws -> NoiseCipherSuite {
        let suite = NoiseCipherSuite.allCases.first { $0.protocolName == vector.protocolName }
        return try #require(suite, "no suite for \(vector.protocolName)")
    }

    @Test("Both spec suites are present in the vector file")
    func vectorCoverage() throws {
        let names = try Set(Self.loadVectors().map(\.protocolName))
        #expect(names == Set(NoiseCipherSuite.allCases.map(\.protocolName)))
    }

    @Test("Handshake and transport bytes match the published vectors")
    func knownAnswers() throws {
        for vector in try Self.loadVectors() {
            let suite = try Self.suite(for: vector)
            let psk = try #require(Psk(bytes: dataFromHex(vector.initPsks[0])))
            let initiatorStatic = try Curve25519.KeyAgreement.PrivateKey(
                rawRepresentation: dataFromHex(vector.initStatic)
            )
            let responderStatic = try Curve25519.KeyAgreement.PrivateKey(
                rawRepresentation: dataFromHex(vector.respStatic)
            )

            var initiator = try NoiseHandshake(
                suite: suite,
                role: .initiator,
                localStaticKey: initiatorStatic,
                remoteStaticPublicKey: responderStatic.publicKey,
                prologue: dataFromHex(vector.initPrologue),
                ephemeralOverride: Curve25519.KeyAgreement.PrivateKey(
                    rawRepresentation: dataFromHex(vector.initEphemeral)
                )
            )
            var responder = try NoiseHandshake(
                suite: suite,
                role: .responder,
                localStaticKey: responderStatic,
                remoteStaticPublicKey: initiatorStatic.publicKey,
                prologue: dataFromHex(vector.respPrologue),
                ephemeralOverride: Curve25519.KeyAgreement.PrivateKey(
                    rawRepresentation: dataFromHex(vector.respEphemeral)
                )
            )

            // Handshake message 1: exact wire bytes, and the responder recovers the payload.
            let message1 = try initiator.writeMessage1(payload: dataFromHex(vector.messages[0].payload))
            #expect(message1 == dataFromHex(vector.messages[0].ciphertext), "\(vector.protocolName) message 1")
            #expect(try responder.readMessage1(message1) == dataFromHex(vector.messages[0].payload))

            // Handshake message 2, PSK mixed at the psk2 position.
            let message2 = try responder.writeMessage2(
                psk: psk, payload: dataFromHex(vector.messages[1].payload)
            )
            #expect(message2 == dataFromHex(vector.messages[1].ciphertext), "\(vector.protocolName) message 2")
            #expect(try initiator.readMessage2(message2, psk: psk) == dataFromHex(vector.messages[1].payload))

            // Final transcript hash matches the vector on both sides.
            let expectedHash = dataFromHex(vector.handshakeHash)
            #expect(initiator.handshakeHash == expectedHash)
            #expect(responder.handshakeHash == expectedHash)

            // Transport messages alternate initiator → responder → initiator → ...
            var initiatorTransport = try initiator.makeTransport()
            var responderTransport = try responder.makeTransport()
            for (index, message) in vector.messages.dropFirst(2).enumerated() {
                let payload = dataFromHex(message.payload)
                let expected = dataFromHex(message.ciphertext)
                let initiatorSends = index.isMultiple(of: 2)
                let ciphertext = if initiatorSends {
                    try initiatorTransport.send.encrypt(associatedData: Data(), plaintext: payload)
                } else {
                    try responderTransport.send.encrypt(associatedData: Data(), plaintext: payload)
                }
                #expect(ciphertext == expected, "\(vector.protocolName) transport message \(index)")
                let decrypted = if initiatorSends {
                    try responderTransport.receive.decrypt(associatedData: Data(), ciphertext: ciphertext)
                } else {
                    try initiatorTransport.receive.decrypt(associatedData: Data(), ciphertext: ciphertext)
                }
                #expect(decrypted == payload)
            }
        }
    }
}
