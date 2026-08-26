import CryptoKit
import Foundation
@testable import SendspinKit
import Testing

private struct CPaceMCFKnownAnswer: Decodable {
    let macKey: String
    let tagA: String
    let tagB: String

    enum CodingKeys: String, CodingKey {
        case macKey = "mac_key"
        case tagA = "tag_a"
        case tagB = "tag_b"
    }
}

@Suite("CPace-X25519 vectors")
struct CPaceX25519VectorTests {
    private let prs = dataFromHex("50617373776f7264")
    private let channelInfo = dataFromHex("0b415f696e69746961746f720b425f726573706f6e646572")
    private let sid = dataFromHex("7e4b4791d6a8ef019b936c79fb7f2c57")
    private let generator = dataFromHex("d04bf6d41f6a289632a2e929fa29bebd51092512a7829fdde7d314b62f05a73f")
    private let scalarA = dataFromHex("21b4f4bd9e64ed355c3eb676a28ebedaf6d8f17bdc365995b319097153044080")
    private let scalarB = dataFromHex("848b0779ff415f0af4ea14df9dd1d3c29ac41d836c7808896c4eba19c51ac40a")
    private let shareA = dataFromHex("1d13c89278cdadd826f6d8d7f887701430f8380ddc17611cdd6dc989ce0c9f32")
    private let shareB = dataFromHex("248cccf6d5cdc3646f0ad593f9e6cef4e69d4945f8372e623512ecea32185623")
    private let shared = dataFromHex("5b067effbdc0b2a0e1d907b21ebb25cfedb96a852179a847c37e43ee71322c6b")
    private let isk =
        dataFromHex(
            "6e19b875f7a561d6b3ca3dbb9ef42ac55de3e717881018204b8922b4d5e53bb2aa82c300bea7b65d2b671da71922ddf6472301b79bc270adfa8bf413285f2263"
        )

    @Test("calculate_generator matches Appendix B.1.1")
    func calculateGenerator() {
        #expect(CPaceX25519.generator(prs: prs, channelInfo: channelInfo, sid: sid) == generator)
    }

    @Test("scalar multiplication matches Appendix B.1.2 through B.1.4")
    func scalarMultiplication() throws {
        #expect(try CPaceX25519.scalarMult(scalar: scalarA, point: generator) == shareA)
        #expect(try CPaceX25519.scalarMult(scalar: scalarB, point: generator) == shareB)
        #expect(try CPaceX25519.scalarMult(scalar: scalarA, point: shareB) == shared)
        #expect(try CPaceX25519.scalarMult(scalar: scalarB, point: shareA) == shared)
    }

    @Test("scalar_mult_vfy masks bit 255, returns Appendix B.1.10 outputs, and aborts weak points")
    func scalarMultVfyLowOrderTable() throws {
        let scalar = dataFromHex("af46e36bf0527c9d3b16154b82465edd62144c0ac1fc5a18506a2244ba449aff")
        let cases: [(String, String?)] = [
            ("0000000000000000000000000000000000000000000000000000000000000000", nil),
            ("0100000000000000000000000000000000000000000000000000000000000000", nil),
            ("ecffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff7f", nil),
            ("e0eb7a7c3b41b8ae1656e3faf19fc46ada098deb9c32b1fd866205165f49b800", nil),
            ("5f9c95bca3508c24b1d0b1559c83ef5b04445cc4581c8e86d8224eddd09f1157", nil),
            ("edffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff7f", nil),
            ("daffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff", "d8e2c776bbacd510d09fd9278b7edcd25fc5ae9adfba3b6e040e8d3b71b21806"),
            ("eeffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff7f", nil),
            ("dbffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff", "c85c655ebe8be44ba9c0ffde69f2fe10194458d137f09bbff725ce58803cdb38"),
            ("d9ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff", "db64dafa9b8fdd136914e61461935fe92aa372cb056314e1231bc4ec12417456"),
            ("cdeb7a7c3b41b8ae1656e3faf19fc46ada098deb9c32b1fd866205165f49b880", "e062dcd5376d58297be2618c7498f55baa07d7e03184e8aada20bca28888bf7a"),
            ("4c9c95bca3508c24b1d0b1559c83ef5b04445cc4581c8e86d8224eddd09f11d7", "993c6ad11c4c29da9a56f7691fd0ff8d732e49de6250b6c2e80003ff4629a175")
        ]
        for (point, expected) in cases {
            if let expected {
                #expect(try CPaceX25519.scalarMult(scalar: scalar, point: dataFromHex(point)) == dataFromHex(expected))
            } else {
                #expect(throws: CPaceError.invalidShare) {
                    try CPaceX25519.scalarMult(scalar: scalar, point: dataFromHex(point))
                }
            }
        }
    }

    @Test("default associated-data values match the pinned CPace ISK")
    func defaultAssociatedDataIsPinned() throws {
        let initiator = try CPace(
            role: .initiator, prs: prs, channelInfo: channelInfo, sid: sid, scalarOverride: scalarA
        )
        let responder = try CPace(
            role: .responder, prs: prs, channelInfo: channelInfo, sid: sid, scalarOverride: scalarB
        )
        let expected = dataFromHex(
            "d90a1cf7ad7fecae899f8c08139243e86782253e214b26abe112cfe8e1b6a6eb2bd8f6bc005b482f42105b8e2d278c6595d0733167a3d798d2623ddd212bb93e"
        )
        #expect(try initiator.derive(remoteShare: responder.publicShare).isk == expected)
        #expect(try responder.derive(remoteShare: initiator.publicShare).isk == expected)
    }

    @Test("initiator and responder derive the Appendix B.1.5 ISK")
    func bothRolesDeriveISK() throws {
        let initiator = try CPaceX25519.derive(CPaceDerivationInput(
            role: .initiator,
            prs: prs,
            channelInfo: channelInfo,
            sid: sid,
            scalar: scalarA,
            remoteShare: shareB,
            initiatorAD: Data("ADa".utf8),
            responderAD: Data("ADb".utf8)
        ))
        let responder = try CPaceX25519.derive(CPaceDerivationInput(
            role: .responder,
            prs: prs,
            channelInfo: channelInfo,
            sid: sid,
            scalar: scalarB,
            remoteShare: shareA,
            initiatorAD: Data("ADa".utf8),
            responderAD: Data("ADb".utf8)
        ))
        #expect(initiator.isk == isk)
        #expect(responder.isk == isk)
    }
}

@Suite("CPace transcript")
struct CPaceTranscriptTests {
    @Test("length-value encoding preserves field boundaries")
    func lengthValueEncoding() {
        #expect(CPaceX25519.lengthValueConcat(Data("1234".utf8), Data("5".utf8), Data(), Data("678".utf8)) == dataFromHex("043132333401350003363738"))
    }

    @Test("changing associated-data order changes ISK")
    func associatedDataBindsTranscript() throws {
        let base = try CPaceX25519.derive(CPaceDerivationInput(
            role: .initiator,
            prs: Data("Password".utf8),
            channelInfo: Data(),
            sid: Data(repeating: 7, count: 16),
            scalar: Data(repeating: 9, count: 32),
            remoteShare: Data(repeating: 8, count: 32),
            initiatorAD: Data("server".utf8),
            responderAD: Data("client".utf8)
        ))
        let swapped = try CPaceX25519.derive(CPaceDerivationInput(
            role: .initiator,
            prs: Data("Password".utf8),
            channelInfo: Data(),
            sid: Data(repeating: 7, count: 16),
            scalar: Data(repeating: 9, count: 32),
            remoteShare: Data(repeating: 8, count: 32),
            initiatorAD: Data("client".utf8),
            responderAD: Data("server".utf8)
        ))
        #expect(base.isk != swapped.isk)
    }

    @Test("MCF tags match the cpace-py known-answer resource")
    func mcfTagsAreKnownAnswers() throws {
        let url = try #require(Bundle.module.url(
            forResource: "cpace-mcf-known-answer",
            withExtension: "json",
            subdirectory: "Resources"
        ))
        let knownAnswer = try JSONDecoder().decode(CPaceMCFKnownAnswer.self, from: Data(contentsOf: url))
        let isk = dataFromHex(
            "6e19b875f7a561d6b3ca3dbb9ef42ac55de3e717881018204b8922b4d5e53bb2aa82c300bea7b65d2b671da71922ddf6472301b79bc270adfa8bf413285f2263"
        )
        let sid = dataFromHex("7e4b4791d6a8ef019b936c79fb7f2c57")
        let tagA = CPaceX25519.mcfTag(
            isk: isk,
            sid: sid,
            share: dataFromHex("1d13c89278cdadd826f6d8d7f887701430f8380ddc17611cdd6dc989ce0c9f32"),
            associatedData: Data("ADa".utf8)
        )
        let tagB = CPaceX25519.mcfTag(
            isk: isk,
            sid: sid,
            share: dataFromHex("248cccf6d5cdc3646f0ad593f9e6cef4e69d4945f8372e623512ecea32185623"),
            associatedData: Data("ADb".utf8)
        )
        #expect(CPaceX25519.mcfKey(isk: isk, sid: sid) == dataFromHex(knownAnswer.macKey))
        #expect(tagA == dataFromHex(knownAnswer.tagA))
        #expect(tagB == dataFromHex(knownAnswer.tagB))
        #expect(CPaceX25519.constantTimeEqual(tagA, tagA))
        #expect(!CPaceX25519.constantTimeEqual(tagA, tagB))
        let truncatedISK = Data(isk.dropLast())
        #expect(CPaceX25519.mcfKey(isk: truncatedISK, sid: sid) != dataFromHex(knownAnswer.macKey))
        #expect(
            CPaceX25519.mcfTag(
                isk: truncatedISK,
                sid: sid,
                share: dataFromHex("1d13c89278cdadd826f6d8d7f887701430f8380ddc17611cdd6dc989ce0c9f32"),
                associatedData: Data("ADa".utf8)
            ) != tagA
        )
    }
}

@Suite("CPace invalid shares")
struct CPaceInvalidShareTests {
    @Test("low-order and bit-255 shares fail")
    func rejectsLowOrderShares() {
        let scalar = dataFromHex("af46e36bf0527c9d3b16154b82465edd62144c0ac1fc5a18506a2244ba449aff")
        let lowOrder = [
            String(repeating: "00", count: 32),
            "0100000000000000000000000000000000000000000000000000000000000000",
            "ecffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff7f",
            "eeffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff7f"
        ]
        for point in lowOrder {
            #expect(throws: CPaceError.invalidShare) {
                try CPaceX25519.scalarMult(scalar: scalar, point: dataFromHex(point))
            }
        }
    }
}

@Suite("Pairing session identifiers")
struct PairingSessionIdentifierTests {
    @Test("uses raw hash and big-endian counter")
    func identifierEncoding() {
        let hash = Data(repeating: 0xAB, count: CPaceSessionIdentifier.handshakeHashLength)
        let sid = CPaceSessionIdentifier.make(handshakeHash: hash, counter: 0x0102_0304)
        #expect(sid == Data("sendspin-pair-pake-v1".utf8) + hash + dataFromHex("01020304"))
    }
}

@Suite("Pairing wrapping")
struct PairingWrapTests {
    private let plaintext = Data((0 ..< PairingWrap.plaintextLength).map(UInt8.init))
    private let label = Data("sendspin-pair-psk-wrap-v1".utf8)
    private let sid = Data(repeating: 0xA5, count: 52)
    private let isk = Data(repeating: 0x5A, count: 64)

    @Test("ChaChaPoly matches the independent zero-nonce fixture")
    func chaChaPoly() throws {
        // The byte-exact fixtures below come from Python cryptography.
        // It uses SHA-256(label || sid || ISK), a zero nonce, and empty AAD.
        let ciphertext = try PairingWrap.wrap(plaintext: plaintext, label: label, sid: sid, isk: isk, suite: .chaChaPoly)
        #expect(ciphertext == dataFromHex("bde5062af30077da392973ca683fec01f2550e840189615c3b1ff716b85603e232490de095bbc4d69aef2a62b77d69d8"))
        #expect(try PairingWrap.unwrap(ciphertext: ciphertext, label: label, sid: sid, isk: isk, suite: .chaChaPoly) == plaintext)
    }

    @Test("AES-GCM matches the independent zero-nonce fixture")
    func aesGCM() throws {
        let ciphertext = try PairingWrap.wrap(plaintext: plaintext, label: label, sid: sid, isk: isk, suite: .aesGCM)
        #expect(ciphertext == dataFromHex("c1c883108b5b352ee92680a44d5fcaf6463caa3d38a26d5fd2eb9c8f3818529905948396140ace20274e3ad57e99c7a8"))
        #expect(try PairingWrap.unwrap(ciphertext: ciphertext, label: label, sid: sid, isk: isk, suite: .aesGCM) == plaintext)
    }

    @Test("wrong key inputs and authenticated data do not match the fixture")
    func fixtureRejectsMutations() throws {
        let expected = dataFromHex("bde5062af30077da392973ca683fec01f2550e840189615c3b1ff716b85603e232490de095bbc4d69aef2a62b77d69d8")
        let mutatedISK = isk.dropLast() + Data([0])
        #expect(try PairingWrap.wrap(plaintext: plaintext, label: label, sid: sid, isk: mutatedISK, suite: .chaChaPoly) != expected)
        #expect(
            try PairingWrap.wrap(
                plaintext: plaintext,
                label: Data("wrong-label".utf8),
                sid: sid,
                isk: isk,
                suite: .chaChaPoly
            ) != expected
        )
        let key = PairingWrap.key(label: label, sid: sid, isk: isk)
        let wrongNonce = try ChaChaPoly.seal(
            plaintext,
            using: key,
            nonce: ChaChaPoly.Nonce(data: Data(repeating: 1, count: PairingWrap.nonceLength)),
            authenticating: Data()
        )
        #expect(wrongNonce.ciphertext + wrongNonce.tag != expected)
        let nonEmptyAD = try ChaChaPoly.seal(
            plaintext,
            using: key,
            nonce: ChaChaPoly.Nonce(data: Data(repeating: 0, count: PairingWrap.nonceLength)),
            authenticating: Data([1])
        )
        #expect(nonEmptyAD.ciphertext + nonEmptyAD.tag != expected)
        do {
            _ = try PairingWrap.unwrap(
                ciphertext: expected,
                label: Data("wrong-label".utf8),
                sid: sid,
                isk: isk,
                suite: .chaChaPoly
            )
            Issue.record("wrong label unexpectedly authenticated")
        } catch PairingWrapError.authenticationFailed {
            // Expected authentication failure.
        }
        do {
            _ = try PairingWrap.unwrap(
                ciphertext: expected,
                label: label,
                sid: sid + Data([0]),
                isk: isk,
                suite: .chaChaPoly
            )
            Issue.record("wrong session identifier unexpectedly authenticated")
        } catch PairingWrapError.authenticationFailed {
            // Expected authentication failure.
        }
    }
}

@Suite("CPace construction")
struct CPaceConstructionTests {
    @Test("production construction generates a scalar and deterministic injection remains available to tests")
    func scalarGenerationAndInjection() throws {
        let scalar = Data(repeating: 0x21, count: CPaceX25519.fieldLength)
        let injected = try CPace(
            role: .initiator,
            prs: Data("Password".utf8),
            sid: Data(repeating: 1, count: 16),
            scalarOverride: scalar
        )
        #expect(injected.scalar == scalar)
        #expect(injected.publicShare.count == CPaceX25519.fieldLength)

        let generated = try CPace(
            role: .responder,
            prs: Data("Password".utf8),
            sid: Data(repeating: 1, count: 16)
        )
        #expect(generated.scalar.count == CPaceX25519.fieldLength)
        #expect(generated.scalar != Data(repeating: 0, count: CPaceX25519.fieldLength))
    }
}
