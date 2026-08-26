import CElligator
import Clibsodium
import CryptoKit
import Foundation

enum CPaceSessionIdentifier {
    static let label = Data("sendspin-pair-pake-v1".utf8)
    static let handshakeHashLength = 32
    static let counterLength = 4

    static func make(handshakeHash: Data, counter: UInt32) -> Data {
        precondition(handshakeHash.count == handshakeHashLength)
        var result = Data()
        result.reserveCapacity(label.count + handshakeHash.count + counterLength)
        result.append(label)
        result.append(handshakeHash)
        result.append(UInt8((counter >> 24) & 0xFF))
        result.append(UInt8((counter >> 16) & 0xFF))
        result.append(UInt8((counter >> 8) & 0xFF))
        result.append(UInt8(counter & 0xFF))
        return result
    }
}

enum CPaceRole: Sendable {
    case initiator
    case responder
}

enum CPaceError: Error, Equatable {
    case invalidInput
    case invalidShare
    case invalidScalar
}

struct CPaceSecrets: Sendable {
    let generator: Data
    let publicShare: Data
    let isk: Data
}

struct CPaceDerivationInput {
    let role: CPaceRole
    let prs: Data
    let channelInfo: Data
    let sid: Data
    let scalar: Data
    let remoteShare: Data
    let initiatorAD: Data
    let responderAD: Data
}

struct CPace: Sendable {
    let role: CPaceRole
    let prs: Data
    let channelInfo: Data
    let sid: Data
    let initiatorAD: Data
    let responderAD: Data
    let scalar: Data
    let generator: Data
    let publicShare: Data

    init(
        role: CPaceRole,
        prs: Data,
        channelInfo: Data = Data(),
        sid: Data,
        initiatorAD: Data = CPaceX25519.defaultInitiatorAD,
        responderAD: Data = CPaceX25519.defaultResponderAD,
        scalarOverride: Data? = nil
    ) throws {
        #if DEBUG
            let scalar = scalarOverride ?? CPace.randomScalar()
        #else
            let scalar = CPace.randomScalar()
        #endif
        guard scalar.count == CPaceX25519.fieldLength else { throw CPaceError.invalidScalar }
        let generator = CPaceX25519.generator(prs: prs, channelInfo: channelInfo, sid: sid)
        let publicShare = try CPaceX25519.scalarMult(scalar: scalar, point: generator)
        self.role = role
        self.prs = prs
        self.channelInfo = channelInfo
        self.sid = sid
        self.initiatorAD = initiatorAD
        self.responderAD = responderAD
        self.scalar = scalar
        self.generator = generator
        self.publicShare = publicShare
    }

    func derive(remoteShare: Data) throws -> CPaceSecrets {
        let sharedPoint = try CPaceX25519.scalarMult(scalar: scalar, point: remoteShare)
        let initiatorShare = role == .initiator ? publicShare : remoteShare
        let responderShare = role == .initiator ? remoteShare : publicShare
        let isk = CPaceX25519.deriveISK(
            sid: sid,
            sharedPoint: sharedPoint,
            transcriptData: CPaceX25519.transcript(
                initiatorShare: initiatorShare,
                initiatorAD: initiatorAD,
                responderShare: responderShare,
                responderAD: responderAD
            )
        )
        return CPaceSecrets(generator: generator, publicShare: publicShare, isk: isk)
    }

    private static func randomScalar() -> Data {
        let key = SymmetricKey(size: .bits256)
        return key.withUnsafeBytes { Data($0) }
    }
}

enum CPaceX25519 {
    static let fieldLength = 32
    static let hashBlockLength = 128
    static let generatorDSI = Data("CPace255".utf8)
    static let iskDSI = Data("CPace255_ISK".utf8)
    static let macDSI = Data("CPaceMac".utf8)
    static let defaultInitiatorAD = Data("server".utf8)
    static let defaultResponderAD = Data("client".utf8)

    private static func prependLength(_ value: Data) -> Data {
        var length = value.count
        var prefix = Data()
        repeat {
            let low = UInt8(length & 0x7F)
            prefix.append(low | (length >= 128 ? 0x80 : 0))
            length >>= 7
        } while length != 0
        prefix.append(value)
        return prefix
    }

    static func lengthValueConcat(_ values: Data...) -> Data {
        values.reduce(into: Data()) { $0.append(prependLength($1)) }
    }

    static func generatorString(prs: Data, channelInfo: Data, sid: Data) -> Data {
        let dsiLength = prependLength(generatorDSI).count
        let prsLength = prependLength(prs).count
        let paddingLength = max(0, hashBlockLength - 1 - prsLength - dsiLength)
        return lengthValueConcat(generatorDSI, prs, Data(repeating: 0, count: paddingLength), channelInfo, sid)
    }

    static func generator(prs: Data, channelInfo: Data, sid: Data) -> Data {
        let input = generatorString(prs: prs, channelInfo: channelInfo, sid: sid)
        let digest = Data(SHA512.hash(data: input)).prefix(fieldLength)
        var inputBytes = Array(digest)
        inputBytes[fieldLength - 1] &= 0x7F
        var outputBytes = Array(repeating: UInt8(0), count: fieldLength)
        outputBytes.withUnsafeMutableBufferPointer { outputBuffer in
            inputBytes.withUnsafeBufferPointer { inputBuffer in
                sendspin_cpace_map_to_curve(outputBuffer.baseAddress!, inputBuffer.baseAddress!)
            }
        }
        return Data(outputBytes)
    }

    static func scalarMult(scalar: Data, point: Data) throws -> Data {
        guard scalar.count == fieldLength, point.count == fieldLength else { throw CPaceError.invalidInput }
        var output = Data(repeating: 0, count: fieldLength)
        // sodium_init() is deliberately absent because this stateless operation receives CryptoKit scalars.
        let result = output.withUnsafeMutableBytes { outputBytes in
            scalar.withUnsafeBytes { scalarBytes in
                point.withUnsafeBytes { pointBytes in
                    crypto_scalarmult_curve25519(
                        outputBytes.bindMemory(to: UInt8.self).baseAddress!,
                        scalarBytes.bindMemory(to: UInt8.self).baseAddress!,
                        pointBytes.bindMemory(to: UInt8.self).baseAddress!
                    )
                }
            }
        }
        var nonzero: UInt8 = 0
        for byte in output {
            nonzero |= byte
        }
        guard result == 0, nonzero != 0 else { throw CPaceError.invalidShare }
        return output
    }

    static func transcript(initiatorShare: Data, initiatorAD: Data, responderShare: Data, responderAD: Data) -> Data {
        lengthValueConcat(initiatorShare, initiatorAD) + lengthValueConcat(responderShare, responderAD)
    }

    static func deriveISK(sid: Data, sharedPoint: Data, transcriptData: Data) -> Data {
        let prefix = lengthValueConcat(iskDSI, sid, sharedPoint)
        return Data(SHA512.hash(data: prefix + transcriptData))
    }

    static func mcfKey(isk: Data, sid: Data) -> Data {
        Data(SHA512.hash(data: macDSI + sid + isk))
    }

    static func mcfTag(isk: Data, sid: Data, share: Data, associatedData: Data) -> Data {
        let message = lengthValueConcat(share, associatedData)
        return Data(HMAC<SHA512>.authenticationCode(for: message, using: SymmetricKey(data: mcfKey(isk: isk, sid: sid))))
    }

    static func constantTimeEqual(_ lhs: Data, _ rhs: Data) -> Bool {
        guard lhs.count == rhs.count else { return false }
        var difference: UInt8 = 0
        for (left, right) in zip(lhs, rhs) {
            difference |= left ^ right
        }
        return difference == 0
    }

    static func derive(_ input: CPaceDerivationInput) throws -> CPaceSecrets {
        let generator = generator(prs: input.prs, channelInfo: input.channelInfo, sid: input.sid)
        let publicShare = try scalarMult(scalar: input.scalar, point: generator)
        let sharedPoint = try scalarMult(scalar: input.scalar, point: input.remoteShare)
        let initiatorShare = input.role == .initiator ? publicShare : input.remoteShare
        let responderShare = input.role == .initiator ? input.remoteShare : publicShare
        let isk = deriveISK(
            sid: input.sid,
            sharedPoint: sharedPoint,
            transcriptData: transcript(
                initiatorShare: initiatorShare,
                initiatorAD: input.initiatorAD,
                responderShare: responderShare,
                responderAD: input.responderAD
            )
        )
        return CPaceSecrets(generator: generator, publicShare: publicShare, isk: isk)
    }
}

enum PairingWrapError: Error, Equatable {
    case invalidLength
    case authenticationFailed
}

/// PairingWrap is single-use for each `(label, sid, ISK)` tuple, so its zero nonce never repeats.
enum PairingWrap {
    static let nonceLength = 12
    static let plaintextLength = 32
    static let ciphertextLength = 48

    static func key(label: Data, sid: Data, isk: Data) -> SymmetricKey {
        SymmetricKey(data: SHA256.hash(data: label + sid + isk))
    }

    static func wrap(plaintext: Data, label: Data, sid: Data, isk: Data, suite: NoiseCipherSuite) throws -> Data {
        guard plaintext.count == plaintextLength else { throw PairingWrapError.invalidLength }
        let symmetricKey = key(label: label, sid: sid, isk: isk)
        let nonceBytes = Data(repeating: 0, count: nonceLength)
        switch suite {
        case .chaChaPoly:
            let box = try ChaChaPoly.seal(plaintext, using: symmetricKey, nonce: ChaChaPoly.Nonce(data: nonceBytes), authenticating: Data())
            return box.ciphertext + box.tag
        case .aesGCM:
            let box = try AES.GCM.seal(plaintext, using: symmetricKey, nonce: AES.GCM.Nonce(data: nonceBytes), authenticating: Data())
            return box.ciphertext + box.tag
        }
    }

    static func unwrap(ciphertext: Data, label: Data, sid: Data, isk: Data, suite: NoiseCipherSuite) throws -> Data {
        guard ciphertext.count == ciphertextLength else { throw PairingWrapError.invalidLength }
        let symmetricKey = key(label: label, sid: sid, isk: isk)
        let nonceBytes = Data(repeating: 0, count: nonceLength)
        let split = ciphertext.index(ciphertext.endIndex, offsetBy: -NoiseCipherSuite.tagLength)
        let body = ciphertext[..<split]
        let tag = ciphertext[split...]
        do {
            switch suite {
            case .chaChaPoly:
                let box = try ChaChaPoly.SealedBox(nonce: ChaChaPoly.Nonce(data: nonceBytes), ciphertext: body, tag: tag)
                return try ChaChaPoly.open(box, using: symmetricKey, authenticating: Data())
            case .aesGCM:
                let box = try AES.GCM.SealedBox(nonce: AES.GCM.Nonce(data: nonceBytes), ciphertext: body, tag: tag)
                return try AES.GCM.open(box, using: symmetricKey, authenticating: Data())
            }
        } catch {
            throw PairingWrapError.authenticationFailed
        }
    }
}
