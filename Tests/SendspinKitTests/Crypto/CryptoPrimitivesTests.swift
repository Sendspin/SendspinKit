import CryptoKit
import Foundation
@testable import SendspinKit
import Testing

/// Hex decoding for spec constants and test vectors.
func dataFromHex(_ hex: String) -> Data {
    precondition(hex.count % 2 == 0, "hex string must have even length")
    var data = Data(capacity: hex.count / 2)
    var index = hex.startIndex
    while index < hex.endIndex {
        let next = hex.index(index, offsetBy: 2)
        guard let byte = UInt8(hex[index ..< next], radix: 16) else {
            preconditionFailure("invalid hex byte in test vector")
        }
        data.append(byte)
        index = next
    }
    return data
}

@Suite("Base64URL")
struct Base64URLTests {
    @Test("Round-trips arbitrary bytes without padding characters")
    func roundTrip() {
        let bytes = Data((0 ..< 77).map { UInt8($0) })
        let encoded = Base64URL.encode(bytes)
        #expect(!encoded.contains("="))
        #expect(!encoded.contains("+"))
        #expect(!encoded.contains("/"))
        #expect(Base64URL.decode(encoded) == bytes)
    }

    @Test("Uses the URL-safe alphabet")
    func urlSafeAlphabet() {
        // 0xfb 0xef 0xff encodes to "++//" in standard base64; base64url must give "--__".
        let encoded = Base64URL.encode(Data([0xFB, 0xEF, 0xFF]))
        #expect(encoded == "--__")
    }

    @Test("Rejects malformed input")
    func rejectsMalformed() {
        #expect(Base64URL.decode("a") == nil)
        #expect(Base64URL.decode("!!!!") == nil)
        #expect(Base64URL.decode("abcd", count: 4) == nil) // decodes to 3 bytes, not 4
    }

    @Test("Rejects padding and standard-alphabet spellings (wire form is strict)")
    func rejectsNonWireSpellings() {
        let bytes = Data([0xFB, 0xEF, 0xFF])
        // Padded, '+', '/', and whitespace variants of otherwise-valid input all fail.
        #expect(Base64URL.decode("--__=") == nil)
        #expect(Base64URL.decode("++//") == nil)
        #expect(Base64URL.decode("ab/c") == nil)
        #expect(Base64URL.decode(" --__") == nil)
        #expect(Base64URL.decode("--__") == bytes)
    }
}

@Suite("PSK derivation")
struct PskTests {
    @Test("Sentinel PSK matches the published spec constant")
    func sentinelPskConstant() {
        let published = dataFromHex("1b5e24dbc1aed95fc2a5a338a90c05df44bd10f5ec1f4cd66cbf86272767b9d3")
        #expect(Psk.sentinel.bytes == published)
    }

    @Test("Sentinel psk_id matches the published spec constant")
    func sentinelPskIdConstant() {
        #expect(Psk.sentinel.pskId == "GFsV9tLaSQm9HcFWpKsgYQOr7wFTvNUtkmFwuVz3zoo")
        let publishedRaw = dataFromHex("185b15f6d2da4909bd1dc156a4ab206103abef0153bcd52d926170b95cf7ce8a")
        #expect(Base64URL.decode(Psk.sentinel.pskId) == publishedRaw)
    }

    @Test("psk_id is 43 characters for any PSK")
    func pskIdLength() {
        #expect(Psk.generate().pskId.count == 43)
    }

    @Test("Base64url round trip and length validation")
    func base64RoundTrip() {
        let psk = Psk.generate()
        #expect(Psk(base64URL: psk.base64URL) == psk)
        #expect(Psk(base64URL: "tooshort") == nil)
        #expect(Psk(base64URL: psk.base64URL + "=") == nil) // padded 44-char spelling
        #expect(Psk(bytes: Data(count: 31)) == nil)
    }

    @Test("Descriptions expose the psk_id, never the secret bytes")
    func descriptionRedactsSecret() {
        let psk = Psk.generate()
        for text in [String(describing: psk), String(reflecting: psk)] {
            #expect(text.contains(psk.pskId))
            // A hex or base64 rendering of the secret would contain its wire form.
            #expect(!text.contains(psk.base64URL))
        }
    }
}

@Suite("PSK candidate selection")
struct PskCandidateTests {
    private let serverId = "server-a"

    @Test("Selects the candidate whose psk_id matches")
    func selectsMatch() {
        let record = Psk.generate()
        let candidates = [
            PskCandidate(psk: .sentinel, category: .sentinel),
            PskCandidate(psk: record, category: .longTerm)
        ]
        let selected = PskCandidate.select(from: candidates, pskId: record.pskId, serverId: serverId)
        #expect(selected?.psk == record)
        #expect(selected?.category == .longTerm)
    }

    @Test("Pairing token matches the specification reference vector")
    func pairingTokenReferenceVector() throws {
        let clientKey = Data((0x00 ... 0x1F).map(UInt8.init))
        let pairingPsk = try #require(Psk(bytes: Data((0xE0 ... 0xFF).map(UInt8.init))))
        let token = PairingToken(clientKey: clientKey, pairingPsk: pairingPsk)
        #expect(token.string == "SP:0AAAQEAYEAUDAOCAJBIFQYDIOB4IBCEQTCQKRMFYYDENBWHA5DYP6BYPC4PSOLZXH5DU6V97M5XXO74HR6LZ7J5PW674PT6X37T6757Y")
        let decoded = try PairingToken(string: "  \(token.string.lowercased())  ")
        #expect(decoded.clientKey == clientKey)
        #expect(decoded.pairingPsk == pairingPsk)
    }

    @Test("Pairing store rejects reserved and duplicate PSK identifiers")
    func pairingStoreUniquenessAndUsed() async throws {
        let pairingPsk = Psk.generate()
        let store = InMemoryPairingRecordStore(pairingPsk: pairingPsk)
        await #expect(throws: PairingRecordStoreError.duplicatePskId) {
            try await store.insert(PairingRecord(psk: pairingPsk))
        }
        let record = PairingRecord(psk: Psk.generate(), serverId: "server")
        try await store.insert(record)
        await store.markUsed(pskId: record.pskId)
        #expect(await (store.listRecords()).first?.used == true)
        await #expect(throws: PairingRecordStoreError.duplicatePskId) {
            try await store.insert(record)
        }
    }

    @Test("Lookup miss returns nil (handshake failure)")
    func lookupMiss() {
        let candidates = [PskCandidate(psk: .sentinel, category: .sentinel)]
        #expect(PskCandidate.select(from: candidates, pskId: Psk.generate().pskId, serverId: serverId) == nil)
    }

    @Test("Stored-pubkey record fails when server_id does not match")
    func storedPubkeyMismatchFails() {
        let record = Psk.generate()
        let candidates = [
            PskCandidate(psk: record, category: .longTerm, requiredServerId: "server-b")
        ]
        #expect(PskCandidate.select(from: candidates, pskId: record.pskId, serverId: serverId) == nil)
        #expect(PskCandidate.select(from: candidates, pskId: record.pskId, serverId: "server-b") != nil)
    }

    @Test("Shared-PSK record accepts any server_id")
    func sharedPskAcceptsAnyServer() {
        let record = Psk.generate()
        let candidates = [PskCandidate(psk: record, category: .longTerm)]
        #expect(PskCandidate.select(from: candidates, pskId: record.pskId, serverId: "anything") != nil)
    }
}

@Suite("SendspinIdentity")
struct SendspinIdentityTests {
    @Test("client_id is 43 base64url characters and stable across restore")
    func clientIdStable() {
        let identity = SendspinIdentity.generate()
        #expect(identity.clientId.count == 43)
        let restored = SendspinIdentity(secretKeyBytes: identity.secretKeyBytes)
        #expect(restored?.clientId == identity.clientId)
        #expect(restored?.publicKeyBytes == identity.publicKeyBytes)
    }

    @Test("Rejects malformed secret key bytes")
    func rejectsMalformedSecret() {
        #expect(SendspinIdentity(secretKeyBytes: Data(count: 5)) == nil)
    }

    @Test("Descriptions expose the client_id, never the secret key")
    func descriptionRedactsSecret() {
        let identity = SendspinIdentity.generate()
        for text in [String(describing: identity), String(reflecting: identity)] {
            #expect(text.contains(identity.clientId))
            #expect(!text.contains(Base64URL.encode(identity.secretKeyBytes)))
        }
    }
}
