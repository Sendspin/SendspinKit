import Foundation
@testable import SendspinKit
import Testing

@MainActor
@Suite("Device-backed client integration")
struct DeviceClientIntegrationTests {
    @Test("one device cannot be owned by two live clients")
    func deviceOwnershipIsExclusive() throws {
        let device = SendspinDevice.ephemeral()
        let first = try makeClient(device: device)

        #expect(throws: SendspinDeviceError.deviceAlreadyOwned) {
            _ = try makeClient(device: device)
        }

        _ = first
    }

    @Test("close releases device ownership for a subsequent client")
    func closeReleasesOwnership() async throws {
        let device = SendspinDevice.ephemeral()
        let first = try makeClient(device: device)
        await first.close()

        let second = try makeClient(device: device)
        await second.close()
    }

    @Test("a failed client configuration releases its device lease")
    func failedConfigurationReleasesLease() throws {
        let device = SendspinDevice.ephemeral()

        #expect(throws: ConfigurationError.playerRoleRequiresConfiguration) {
            _ = try SendspinClient(
                device: device,
                name: "Invalid Device Client",
                roles: [.playerV1],
                access: .allowUnpaired
            )
        }

        let recovered = try makeClient(device: device)
        _ = recovered
    }

    @Test("static-code presentation requires a provisioned device code")
    func staticCodeRequiresProvisioning() throws {
        let device = SendspinDevice.ephemeral()

        #expect(throws: SendspinDeviceError.invalidStaticCode) {
            _ = try makeClient(device: device, pairing: .staticCode)
        }

        let recovered = try makeClient(device: device)
        _ = recovered
    }

    @Test("explicit paired-only access is advertised in client hello")
    func pairedOnlyAccessMapsToHello() async throws {
        let hello = try await hello(
            device: SendspinDevice.ephemeral(),
            pairing: .tokenOnly,
            access: .pairedOnly
        )

        #expect(hello.payload.unpairedAccess.enabled == false)
        #expect(hello.payload.supportedPairMethods[PairMethod.pairingPsk] != nil)
        #expect(hello.payload.supportedPairMethods[PairMethod.dynamicPairingCode] == nil)
    }

    @Test("explicit unpaired access is advertised in client hello")
    func allowUnpairedAccessMapsToHello() async throws {
        let hello = try await hello(
            device: SendspinDevice.ephemeral(),
            pairing: .tokenOnly,
            access: .allowUnpaired
        )

        #expect(hello.payload.unpairedAccess.enabled)
    }

    @Test("token-only presentation advertises only the operator token method")
    func tokenOnlyDescriptor() async throws {
        let hello = try await hello(
            device: SendspinDevice.ephemeral(),
            pairing: .tokenOnly,
            access: .allowUnpaired
        )
        let methods = hello.payload.supportedPairMethods

        #expect(Set(methods.keys) == [PairMethod.pairingPsk])
        #expect(methods[PairMethod.pairingPsk]?.locations == ["operator"])
    }

    @Test("digit-display presentation advertises digits on the display")
    func digitDisplayDescriptor() async throws {
        let hello = try await hello(
            device: SendspinDevice.ephemeral(),
            pairing: .digitDisplay,
            access: .allowUnpaired
        )
        let descriptor = try #require(hello.payload.supportedPairMethods[PairMethod.dynamicPairingCode])

        #expect(descriptor.outChannels == ["display"])
        #expect(descriptor.formats == ["digits"])
        #expect(descriptor.digitAudio == nil)
    }

    @Test("speaker presentation advertises digits on the speaker")
    func speakerDescriptor() async throws {
        let audio = DigitAudioDescriptor(codec: .pcm, sampleRate: 8_000, bitDepth: 16, maxBytes: 20)
        let hello = try await hello(
            device: SendspinDevice.ephemeral(),
            pairing: .speaker(audio: audio),
            access: .allowUnpaired
        )
        let descriptor = try #require(hello.payload.supportedPairMethods[PairMethod.dynamicPairingCode])

        #expect(descriptor.outChannels == ["speaker"])
        #expect(descriptor.formats == ["digits"])
        #expect(descriptor.digitAudio == audio)
    }

    @Test("changing to paired-only closes sentinel playback")
    func policyDisablesSentinelPlayback() async throws {
        let device = SendspinDevice.ephemeral()
        let client = try makePlayerClient(device: device, access: .allowUnpaired)
        let transport = MockTransport()
        let server = MockNoiseServer(transport: transport, psk: .sentinel)
        async let accepted: Void = client.acceptConnection(transport)
        try await server.establishSession(activities: [.playback], activeRoles: [.playerV1])
        try await accepted
        try await waitForState(client, expected: .connected, timeout: .seconds(3))

        try await client.setAccessPolicy(.pairedOnly)

        let goodbyeData = try #require(await server.clientJSONMessages(ofType: ClientGoodbyeMessage.typeString).last)
        let goodbye = try JSONDecoder().decode(ClientGoodbyeMessage.self, from: goodbyeData)
        #expect(goodbye.payload.reason == .pairingRequired)
        #expect(await server.disconnectCalled)
        #expect(client.accessPolicy == .pairedOnly)
    }

    @Test("changing to paired-only preserves playback on a paired connection")
    func policyPreservesPairedPlayback() async throws {
        let device = SendspinDevice.ephemeral()
        let client = try makePlayerClient(device: device, access: .allowUnpaired)
        let transport = MockTransport()
        let longTermPsk = Psk.generate()
        let server = MockNoiseServer(transport: transport, psk: longTermPsk)
        let serverId = await server.serverId
        try await device.insertOrReplace(PairingRecord(psk: longTermPsk, serverId: serverId))

        async let accepted: Void = client.acceptConnection(transport)
        try await server.establishSession(activities: [.playback], activeRoles: [.playerV1])
        try await accepted
        try await waitForState(client, expected: .connected, timeout: .seconds(3))

        try await client.setAccessPolicy(.pairedOnly)

        #expect(client.accessPolicy == .pairedOnly)
        #expect(client.connectionState == .connected)
        #expect(await server.disconnectCalled == false)
        #expect(await server.clientJSONMessages(ofType: ClientGoodbyeMessage.typeString).isEmpty)
    }

    @Test("public device pairing persists through reload and reconnects with the durable PSK")
    func pairingPersistsThroughDeviceReload() async throws {
        let storage = DurableDeviceIntegrationStorage()
        let firstDevice = try await SendspinDevice.open(storage: storage)
        let firstClient = try makeClient(device: firstDevice, access: .allowUnpaired)
        let events = firstClient.events()
        let transport = MockTransport()
        let server = MockNoiseServer(transport: transport, psk: .sentinel)

        async let accepted: Void = firstClient.acceptConnection(transport)
        try await server.establishSession()
        try await accepted
        try await server.beginRehandshake(to: firstDevice.pairingPsk, pskCategoryOverride: .pairing)
        #expect(await waitUntil { await server.rehandshakeComplete })
        #expect(await server.clientJSONMessages(ofType: ClientHelloMessage.typeString).count == 1)
        try await server.sendJSON(
            #"{"type":"server/activate","payload":{"activities":["pairing"],"active_roles":[],"pairing":{"method":"pairing_psk"}}}"#
        )
        #expect(await waitUntil {
            await server.clientJSONMessages(ofType: ClientPairFinalizeMessage.typeString).count == 1
        })
        let finalizeData = try #require(await server.clientJSONMessages(ofType: ClientPairFinalizeMessage.typeString).first)
        let finalize = try JSONDecoder().decode(ClientPairFinalizeMessage.self, from: finalizeData)
        let durablePsk = try #require(Psk(base64URL: finalize.payload.longTermPsk))
        try await server.sendJSON(#"{"type":"server/pair-finalize","payload":{}}"#)
        #expect(await collectClientEvent(from: events) {
            if case .paired = $0 {
                return true
            }
            return false
        } != nil)
        let firstRecords = try await firstDevice.listRecords()
        #expect(await firstRecords == [PairingRecord(psk: durablePsk, serverId: server.serverId)])

        await firstClient.close()
        let reloadedDevice = try await SendspinDevice.open(storage: storage)
        #expect(try await reloadedDevice.listRecords() == firstRecords)
        let secondClient = try makeClient(device: reloadedDevice, access: .pairedOnly)
        let secondTransport = MockTransport()
        let secondServer = MockNoiseServer(
            transport: secondTransport,
            staticKey: server.staticKey,
            psk: durablePsk
        )
        async let acceptedAgain: Void = secondClient.acceptConnection(secondTransport)
        try await secondServer.establishSession()
        try await acceptedAgain
        #expect(await waitUntil { await MainActor.run { secondClient.connectionState == .connected } })
        await secondClient.close()
    }

    @Test("changing policy updates runtime before pending transport teardown")
    func policyUpdatesRuntimeBeforePendingDisconnect() async throws {
        let device = SendspinDevice.ephemeral()
        let client = try makePlayerClient(device: device, access: .allowUnpaired)
        let baseTransport = MockTransport()
        let transport = PolicyBlockingTransport(base: baseTransport)
        let server = MockNoiseServer(transport: baseTransport, psk: .sentinel)
        let accepted = Task { try? await client.acceptConnection(transport) }
        try await server.beginAdmission()

        let update = Task { try? await client.setAccessPolicy(.pairedOnly) }
        #expect(await waitUntil { await transport.isDisconnectWaiting })
        let runtime = try #require(client.pairingConfiguration?.runtime)
        #expect(await runtime.snapshot().unpairedAccessEnabled == false)

        await transport.releaseDisconnect()
        _ = await update.value
        _ = await accepted.value

        #expect(await transport.disconnectCalled)
        #expect(client.connection == nil)
        #expect(client.connectionState == .disconnected)
        #expect(client.accessPolicy == .pairedOnly)
    }

    private func makeClient(
        device: SendspinDevice,
        pairing: PairingPresentation = .tokenOnly,
        access: AccessPolicy = .allowUnpaired
    ) throws -> SendspinClient {
        try SendspinClient(
            device: device,
            name: "Device Integration Client",
            roles: [],
            pairing: pairing,
            access: access
        )
    }

    private func makePlayerClient(
        device: SendspinDevice,
        access: AccessPolicy
    ) throws -> SendspinClient {
        let playerConfig = try PlayerConfiguration(
            bufferCapacity: 1_024,
            supportedFormats: [
                AudioFormatSpec(codec: .pcm, channels: 2, sampleRate: 48_000, bitDepth: 16)
            ]
        )
        return try SendspinClient(
            device: device,
            name: "Device Player Client",
            roles: [.playerV1],
            playerConfig: playerConfig,
            access: access
        )
    }

    private func hello(
        device: SendspinDevice,
        pairing: PairingPresentation,
        access: AccessPolicy
    ) async throws -> ClientHelloMessage {
        let client = try makeClient(device: device, pairing: pairing, access: access)
        let transport = MockTransport()
        let server = MockNoiseServer(transport: transport, psk: .sentinel)
        async let accepted: Void = client.acceptConnection(transport)
        try await server.establishSession()
        try await accepted
        let data = try #require(await server.clientJSONMessages(ofType: ClientHelloMessage.typeString).last)
        let result = try JSONDecoder().decode(ClientHelloMessage.self, from: data)
        await client.close()
        return result
    }
}

private actor DurableDeviceIntegrationStorage: SendspinDeviceStorage {
    private var snapshot: Data?

    func load() async throws -> Data? {
        snapshot
    }

    func create(_ data: Data) async throws -> Bool {
        guard snapshot == nil else { return false }
        snapshot = data
        return true
    }

    func save(_ data: Data) async throws {
        snapshot = data
    }
}

private actor PolicyBlockingTransport: ClientDialingTransport {
    let base: MockTransport
    private var disconnectContinuation: CheckedContinuation<Void, Never>?
    private var shouldBlockDisconnect = true
    private(set) var isDisconnectWaiting = false
    private(set) var isConnected = true
    private(set) var closeReason: TransportCloseReason?
    private(set) var disconnectCalled = false

    init(base: MockTransport) {
        self.base = base
    }

    func connect() async throws {
        try await base.connect()
        isConnected = true
        closeReason = nil
    }

    func nextFrame() async -> TransportFrame? {
        await base.nextFrame()
    }

    func sendRawText(_ text: String) async throws {
        try await base.sendRawText(text)
    }

    func sendBinary(_ data: Data) async throws {
        try await base.sendBinary(data)
    }

    func disconnect() async {
        if shouldBlockDisconnect {
            shouldBlockDisconnect = false
            isDisconnectWaiting = true
            await withCheckedContinuation { continuation in
                disconnectContinuation = continuation
            }
            isDisconnectWaiting = false
        }
        isConnected = false
        closeReason = .cancelled
        disconnectCalled = true
        await base.disconnect()
    }

    func releaseDisconnect() {
        disconnectContinuation?.resume()
        disconnectContinuation = nil
    }
}
