import Foundation
@testable import SendspinKit
import Testing

private enum DigitAudioTestError: Error { case missingMessage(String) }

private struct DigitAudioSession {
    let client: SendspinClient
    let server: MockNoiseServer
    let events: AsyncStream<ClientEvent>
    let store: InMemoryPairingRecordStore
    let descriptor: DigitAudioDescriptor
}

@MainActor
private func makeDigitAudioSession(
    descriptor: DigitAudioDescriptor = DigitAudioDescriptor(codec: .pcm, sampleRate: 8_000, bitDepth: 16, maxBytes: 20),
    store: InMemoryPairingRecordStore? = nil
) async throws -> DigitAudioSession {
    let pairingPsk = Psk.generate()
    let resolvedStore = store ?? InMemoryPairingRecordStore(pairingPsk: pairingPsk)
    let pairing = PairingConfiguration(
        pairingPsk: pairingPsk,
        store: resolvedStore,
        enabled: false,
        dynamicPairingCodeEnabled: true,
        digitAudio: descriptor
    )
    let client = try SendspinClient(
        identity: .generate(),
        name: "Digit Audio Test Client",
        roles: [],
        pairing: pairing,
        audioOutputCapabilityProvider: AudioOutputCapabilityService()
    )
    let transport = MockTransport()
    let server = MockNoiseServer(transport: transport, psk: .sentinel)
    let events = client.events()
    async let accepted: Void = client.acceptConnection(transport)
    try await server.establishSession(activities: [], activeRoles: [])
    try await accepted
    #expect(await waitUntil { await MainActor.run { client.connectionState == .connected } })
    return DigitAudioSession(client: client, server: server, events: events, store: resolvedStore, descriptor: descriptor)
}

private func activateDigits(_ server: MockNoiseServer) async throws {
    let activation = ServerActivateMessage(
        payload: ServerActivatePayload(
            activities: [.pairing],
            activeRoles: [],
            pairing: PairingDirective(method: PairMethod.dynamicPairingCode, format: PairingCodeFormat.digits.rawValue)
        )
    )
    let data = try JSONEncoder().encode(activation)
    let text = try #require(String(data: data, encoding: .utf8))
    try await server.sendJSON(text)
}

private func digitFrame(_ digit: UInt8, payload: Data = Data([0, 0])) -> Data {
    var frame = Data([BinaryMessageType.digitAudioClip.rawValue, digit])
    frame.append(payload)
    return frame
}

private func sendPCMClips(_ server: MockNoiseServer, digits: Range<UInt8> = UInt8(0) ..< UInt8(DigitAudioPackConstants.clipCount)) async {
    for digit in digits {
        await server.injectBinary(digitFrame(digit))
    }
}

private func waitForClientMessage(
    _ server: MockNoiseServer,
    type: String,
    count: Int = 1
) async throws -> Data {
    #expect(await waitUntil(timeout: .seconds(3)) { await server.clientJSONMessages(ofType: type).count >= count })
    guard let message = await server.clientJSONMessages(ofType: type).last else {
        throw DigitAudioTestError.missingMessage(type)
    }
    return message
}

private func assertSilentProtocolClose(_ session: DigitAudioSession) async throws {
    #expect(await waitUntil(timeout: .seconds(3)) { await session.server.disconnectCalled })
    #expect(await session.server.clientJSONMessages(ofType: PairAbortMessage.typeString).isEmpty)
    #expect(await session.server.clientJSONMessages(ofType: ClientGoodbyeMessage.typeString).isEmpty)
    #expect(await waitUntil(timeout: .seconds(3)) {
        await MainActor.run { session.client.connectionState == .disconnected }
    })
}

private func nextCode(_ events: AsyncStream<ClientEvent>) async -> PairingCodeEmission? {
    await collectClientEvent(from: events, timeout: .seconds(3)) {
        if case .pairingCodeChanged(.some) = $0 {
            return true
        }
        return false
    }.flatMap { event in
        guard case let .pairingCodeChanged(emission?) = event else {
            return nil
        }
        return emission
    }
}

@Suite("Digit audio wire fixtures", .timeLimit(.minutes(1)))
struct DigitAudioWireFixtureTests {
    @Test("raw type-2 digit frames reach the pairing pack and emit ten clips")
    func rawFramesReachPairingState() async throws {
        let session = try await makeDigitAudioSession()
        try await activateDigits(session.server)
        _ = try await waitForClientMessage(session.server, type: ClientPairInitMessage.typeString)
        await sendPCMClips(session.server)
        try await session.server.sendJSON(#"{"type":"server/pair-init","payload":{"nonce_A":"AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"}}"#)
        let emission = try #require(await nextCode(session.events))
        #expect(emission.digitAudioPack?.clips.map(\.digit) == Array(UInt8(0) ..< UInt8(DigitAudioPackConstants.clipCount)))
        #expect(emission.digitAudioPack?.clips.count == DigitAudioPackConstants.clipCount)
        await session.client.disconnect()
    }

    @Test("type-2 stragglers outside a pairing context are discarded silently")
    func stragglerIsDiscarded() async throws {
        let session = try await makeDigitAudioSession()
        await session.server.injectBinary(digitFrame(0))
        try await Task.sleep(for: .milliseconds(50))
        #expect(await !session.server.disconnectCalled)
        #expect(await session.server.clientJSONMessages(ofType: PairAbortMessage.typeString).isEmpty)
        await session.client.disconnect()
    }
}

@Suite("Digit audio pairing", .timeLimit(.minutes(1)))
struct DigitAudioPairingTests {
    @Test("clip before client/pair-init closes silently")
    func clipBeforePairInitCloses() async throws {
        let store = InMemoryPairingRecordStore()
        for _ in 0 ..< dynamicPairingFailureEscalationThreshold {
            _ = await store.incrementDynamicPairingFailureCount()
        }
        let session = try await makeDigitAudioSession(store: store)
        try await activateDigits(session.server)
        _ = try await waitForClientMessage(session.server, type: ClientPairPendingMessage.typeString)
        await session.server.injectBinary(digitFrame(0))
        try await assertSilentProtocolClose(session)
    }

    @Test("clip after server/pair-init closes silently")
    func clipAfterPairInitCloses() async throws {
        let session = try await makeDigitAudioSession()
        try await activateDigits(session.server)
        _ = try await waitForClientMessage(session.server, type: ClientPairInitMessage.typeString)
        await sendPCMClips(session.server)
        try await session.server.sendJSON(#"{"type":"server/pair-init","payload":{"nonce_A":"AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"}}"#)
        _ = try #require(await nextCode(session.events))
        await session.server.injectBinary(digitFrame(0))
        try await assertSilentProtocolClose(session)
    }

    @Test("matching real libFLAC clips are accepted at the connection")
    func matchingFLACPasses() async throws {
        let descriptor = DigitAudioDescriptor(codec: .flac, sampleRate: 44_100, bitDepth: 16, maxBytes: 100_000)
        let session = try await makeDigitAudioSession(descriptor: descriptor)
        try await activateDigits(session.server)
        _ = try await waitForClientMessage(session.server, type: ClientPairInitMessage.typeString)
        for digit in UInt8(0) ..< UInt8(DigitAudioPackConstants.clipCount) {
            await session.server.injectBinary(digitFrame(digit, payload: FLACChannelSafetyTests.monoFLAC))
        }
        try await session.server.sendJSON(#"{"type":"server/pair-init","payload":{"nonce_A":"AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"}}"#)
        let emission = try #require(await nextCode(session.events))
        #expect(emission.digitAudioPack?.clips.count == DigitAudioPackConstants.clipCount)
        await session.client.disconnect()
    }

    @Test("a real FLAC stream with a descriptor mismatch closes")
    func mismatchedFLACCloses() async throws {
        let descriptor = DigitAudioDescriptor(codec: .flac, sampleRate: 48_000, bitDepth: 16, maxBytes: 100_000)
        let session = try await makeDigitAudioSession(descriptor: descriptor)
        try await activateDigits(session.server)
        _ = try await waitForClientMessage(session.server, type: ClientPairInitMessage.typeString)
        await session.server.injectBinary(digitFrame(0, payload: FLACChannelSafetyTests.monoFLAC))
        try await assertSilentProtocolClose(session)
    }

    @Test("Opus clips exceeding the granule duration limit close")
    func overlongOpusCloses() async throws {
        let descriptor = DigitAudioDescriptor(codec: .opus, sampleRate: DigitAudioPackConstants.opusGranuleRate, bitDepth: 16, maxBytes: 1_024)
        let session = try await makeDigitAudioSession(descriptor: descriptor)
        try await activateDigits(session.server)
        _ = try await waitForClientMessage(session.server, type: ClientPairInitMessage.typeString)
        let overlong = Self.oggClip(
            granule: UInt64(
                DigitAudioPackConstants.opusGranuleRate
                    * (DigitAudioPackConstants.maximumDurationSeconds + 1)
            )
        )
        await session.server.injectBinary(digitFrame(0, payload: overlong))
        try await assertSilentProtocolClose(session)
    }

    @Test("undecodable Opus garbage closes")
    func garbageOpusCloses() async throws {
        let descriptor = DigitAudioDescriptor(codec: .opus, sampleRate: DigitAudioPackConstants.opusGranuleRate, bitDepth: 16, maxBytes: 1_024)
        let session = try await makeDigitAudioSession(descriptor: descriptor)
        try await activateDigits(session.server)
        _ = try await waitForClientMessage(session.server, type: ClientPairInitMessage.typeString)
        await session.server.injectBinary(digitFrame(0, payload: Data("not an ogg stream".utf8)))
        try await assertSilentProtocolClose(session)
    }

    @Test("max_bytes is cumulative across clips")
    func cumulativeMaxBytesCloses() async throws {
        let descriptor = DigitAudioDescriptor(codec: .pcm, sampleRate: 8_000, bitDepth: 16, maxBytes: 4)
        let session = try await makeDigitAudioSession(descriptor: descriptor)
        try await activateDigits(session.server)
        _ = try await waitForClientMessage(session.server, type: ClientPairInitMessage.typeString)
        await session.server.injectBinary(digitFrame(0))
        await session.server.injectBinary(digitFrame(1))
        await session.server.injectBinary(digitFrame(2))
        try await assertSilentProtocolClose(session)
    }

    @Test("an incomplete pack is rejected when server/pair-init arrives")
    func incompletePackCloses() async throws {
        let session = try await makeDigitAudioSession()
        try await activateDigits(session.server)
        _ = try await waitForClientMessage(session.server, type: ClientPairInitMessage.typeString)
        await session.server.injectBinary(digitFrame(0))
        try await session.server.sendJSON(#"{"type":"server/pair-init","payload":{"nonce_A":"AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"}}"#)
        try await assertSilentProtocolClose(session)
    }

    @Test("ending an attempt discards clips before the next attempt")
    func attemptEndDiscardsClips() async throws {
        let session = try await makeDigitAudioSession()
        try await activateDigits(session.server)
        _ = try await waitForClientMessage(session.server, type: ClientPairInitMessage.typeString)
        await session.server.injectBinary(digitFrame(0))
        try await session.server.sendJSON(#"{"type":"pair/abort","payload":{"reason":"user_cancelled"}}"#)
        try await Task.sleep(for: .milliseconds(50))
        try await activateDigits(session.server)
        _ = try await waitForClientMessage(session.server, type: ClientPairInitMessage.typeString, count: 2)
        await sendPCMClips(session.server)
        try await session.server.sendJSON(#"{"type":"server/pair-init","payload":{"nonce_A":"AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"}}"#)
        let emission = try #require(await nextCode(session.events))
        #expect(emission.digitAudioPack?.clips.count == DigitAudioPackConstants.clipCount)
        await session.client.disconnect()
    }

    @Test("a superseding activation discards clips before the next attempt")
    func supersedingActivationDiscardsClips() async throws {
        let session = try await makeDigitAudioSession()
        try await activateDigits(session.server)
        _ = try await waitForClientMessage(session.server, type: ClientPairInitMessage.typeString)
        await session.server.injectBinary(digitFrame(0))
        try await session.server.sendActivation(activities: [], activeRoles: [])
        try await Task.sleep(for: .milliseconds(50))
        try await activateDigits(session.server)
        _ = try await waitForClientMessage(session.server, type: ClientPairInitMessage.typeString, count: 2)
        await sendPCMClips(session.server)
        try await session.server.sendJSON(#"{"type":"server/pair-init","payload":{"nonce_A":"AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"}}"#)
        let emission = try #require(await nextCode(session.events))
        #expect(emission.digitAudioPack?.clips.count == DigitAudioPackConstants.clipCount)
        await session.client.disconnect()
    }

    private static func oggClip(granule: UInt64) -> Data {
        var head = Data("OpusHead".utf8)
        head.append(contentsOf: [1, 1, 0, 0])
        head.append(Data(repeating: 0, count: DigitAudioPackConstants.opusHeadLength - head.count))
        var result = page(granule: 0, flags: 0x02, payload: head)
        result.append(page(granule: granule, flags: 0, payload: Data([0])))
        return result
    }

    private static func page(granule: UInt64, flags: UInt8, payload: Data) -> Data {
        var page = Data("OggS".utf8)
        page.append(contentsOf: [0, flags])
        var value = granule
        for _ in 0 ..< MemoryLayout<UInt64>.size {
            page.append(UInt8(value & 0xFF))
            value >>= 8
        }
        page.append(Data(repeating: 0, count: 12))
        page.append(0)
        page.append(1)
        page.append(UInt8(payload.count))
        page.append(payload)
        return page
    }
}

@Suite("Speaker dynamic pairing transcript", .timeLimit(.minutes(1)))
struct SpeakerDigitAudioTranscriptTests {
    @Test("speaker advertisement carries a complete ten-clip pack through CPace auth")
    func speakerTranscript() async throws {
        let descriptor = DigitAudioDescriptor(codec: .pcm, sampleRate: 8_000, bitDepth: 16, maxBytes: 20)
        let session = try await makeDigitAudioSession(descriptor: descriptor)
        let hello = try #require(await session.server.clientJSONMessages(ofType: ClientHelloMessage.typeString).last)
        let decodedHello = try JSONDecoder().decode(ClientHelloMessage.self, from: hello)
        let method = try #require(decodedHello.payload.supportedPairMethods[PairMethod.dynamicPairingCode])
        #expect(method.outChannels == ["display", "speaker"])
        #expect(method.digitAudio == descriptor)

        try await activateDigits(session.server)
        let initData = try await waitForClientMessage(session.server, type: ClientPairInitMessage.typeString)
        let pairInit = try JSONDecoder().decode(ClientPairInitMessage.self, from: initData)
        await sendPCMClips(session.server)
        let nonceA = Data(repeating: 0, count: 32)
        let serverPairInit = ServerPairInitMessage(
            payload: ServerPairInitPayload(nonceA: Base64URL.encode(nonceA))
        )
        let pairInitData = try JSONEncoder().encode(serverPairInit)
        guard let pairInitText = String(data: pairInitData, encoding: .utf8) else {
            throw DigitAudioTestError.missingMessage("server/pair-init")
        }
        try await session.server.sendJSON(pairInitText)
        let emission = try #require(await nextCode(session.events))
        #expect(emission.format == .digits)
        #expect(emission.digitAudioPack?.clips.count == DigitAudioPackConstants.clipCount)

        let handshakeHash = try #require(await session.server.establishedHandshakeHash)
        let sid = CPaceSessionIdentifier.make(handshakeHash: handshakeHash, counter: pairInit.payload.pairingIndex)
        let cpace = try CPace(role: .initiator, prs: Data(emission.payload.utf8), sid: sid)
        let auth = ServerPairAuthMessage(
            payload: ServerPairAuthPayload(pakeMsg1: Base64URL.encode(cpace.publicShare))
        )
        let authData = try JSONEncoder().encode(auth)
        guard let authText = String(data: authData, encoding: .utf8) else {
            throw DigitAudioTestError.missingMessage("server/pair-auth")
        }
        try await session.server.sendJSON(authText)
        _ = try await waitForClientMessage(session.server, type: ClientPairAuthMessage.typeString)
        #expect(await !session.server.disconnectCalled)
        await session.client.disconnect()
    }
}

@Suite("Dynamic pairing after re-handshake", .timeLimit(.minutes(1)))
struct RehandshakeDigitAudioTests {
    @Test("re-handshake preserves live dynamic digits admission")
    func rehandshakeAdmitsDigitsWithoutMethodAbort() async throws {
        let descriptor = DigitAudioDescriptor(codec: .pcm, sampleRate: 8_000, bitDepth: 16, maxBytes: 20)
        let session = try await makeDigitAudioSession(descriptor: descriptor)
        let helloCount = await session.server.clientJSONMessages(ofType: ClientHelloMessage.typeString).count
        try await session.server.beginRehandshake(to: .sentinel)
        #expect(await waitUntil { await session.server.rehandshakeComplete })
        try await session.server.sendJSON(#"{"type":"server/hello","payload":{"name":"Rehandshake Server"}}"#)
        #expect(await waitUntil { await session.server.clientJSONMessages(ofType: ClientHelloMessage.typeString).count == helloCount + 1 })
        try await activateDigits(session.server)
        _ = try await waitForClientMessage(session.server, type: ClientPairInitMessage.typeString)
        #expect(await session.server.clientJSONMessages(ofType: PairAbortMessage.typeString).isEmpty)
        await session.client.disconnect()
    }
}
