import Foundation
@testable import SendspinKit

/// A copyable reference box for the move-only channel handoff. The connection
/// consumes the client-side channel before the box is returned.
final class EstablishedConnectionFixture {
    let connection: SendspinConnection
    let server: MockNoiseServer
    let transport: MockTransport

    init(connection: SendspinConnection, server: MockNoiseServer, transport: MockTransport) {
        self.connection = connection
        self.server = server
        self.transport = transport
    }
}

/// Direct-connection path: establish Noise, admit metadata before construction,
/// then transfer the encrypted channel to `SendspinConnection`.
func makeEstablishedConnection(
    transport suppliedTransport: MockTransport? = nil,
    clock: any ClockSyncProtocol = ClockSynchronizer(),
    activities: Set<Activity> = [],
    activeRoles: Set<VersionedRole> = [.playerV1],
    psk: Psk = .sentinel,
    pskCategory: PskCategory = .sentinel,
    matchedPskId: String? = nil,
    pairingStore: (any PairingRecordStore)? = nil,
    pairingConfigurationRuntime: PairingConfigurationRuntime? = nil,
    unpairedAccessEnabled: Bool = true,
    engine: AudioEngine? = nil,
    audioSink: AsyncStream<AudioChunk>.Continuation = AsyncStream<AudioChunk>.makeStream().1,
    artworkSink: AsyncStream<ArtworkData>.Continuation = AsyncStream<ArtworkData>.makeStream().1,
    visualizerSink: AsyncStream<VisualizerData>.Continuation = AsyncStream<VisualizerData>.makeStream().1,
    emitRawAudio: Bool = true,
    validity: SessionValidityToken = SessionValidityToken(),
    advertisedCommands: Set<PlayerCommand> = [.setOutputDelay],
    roles: Set<VersionedRole> = [.playerV1],
    initialVolume: Int = 100,
    initialMuted: Bool = false,
    initialArtworkState: ArtworkStateObject? = nil,
    initialVisualizerState: VisualizerStateObject? = nil,
    scheduleNow: @escaping @Sendable () -> Int64 = { MonotonicClock.absoluteMicroseconds() },
    scheduleSleep: @escaping @Sendable (Duration) async throws -> Void = { duration in
        try await Task.sleep(for: duration)
    },
    requiredLeadTimeMs: Int = defaultRequiredLeadTimeMs,
    minBufferMs: Int = defaultMinBufferMs,
    artworkObserver: (@Sendable (ArtworkData) -> Void)? = nil,
    startConnection: Bool = true
) async throws -> EstablishedConnectionFixture {
    let transport = suppliedTransport ?? MockTransport()
    let server = MockNoiseServer(transport: transport, psk: psk)
    let clientIdentity = SendspinIdentity.generate()
    let accepted = Task { () throws in
        try await server.respondToHandshake()
    }

    let outcome = try await NoiseSessionEstablisher.establish(
        on: transport,
        identity: clientIdentity,
        suite: .chaChaPoly,
        candidates: [PskCandidate(psk: psk, category: pskCategory)]
    )
    try await accepted.value
    let admittedServerId = outcome.serverId
    let outcomeIdentityPrivateKey = clientIdentity.privateKey
    let outcomeServerStaticPublicKey = outcome.serverStaticPublicKey
    let outcomeSuite = outcome.suite
    let channel = outcome.takeChannel()
    await transport.installEncryptedTextSender(server.encryptedTextSender())
    await transport.installEncryptedBinarySender(server.encryptedBinarySender())

    let directEngine: AudioEngine = if let engine {
        engine
    } else {
        try AudioEngine(
            clock: clock,
            config: PlayerConfiguration(
                bufferCapacity: 100_000,
                supportedFormats: [AudioFormatSpec(codec: .pcm, channels: 2, sampleRate: 44_100, bitDepth: 16)]
            )
        )
    }

    let connection = SendspinConnection(
        transport: transport,
        channel: channel,
        serverId: admittedServerId,
        serverName: "Direct Test Server",
        activities: activities,
        activeRoles: activeRoles,
        pskCategory: pskCategory,
        matchedPskId: matchedPskId ?? psk.pskId,
        pairingStore: pairingStore,
        pairingConfigurationRuntime: pairingConfigurationRuntime,
        identityPrivateKey: outcomeIdentityPrivateKey,
        serverStaticPublicKey: outcomeServerStaticPublicKey,
        suite: outcomeSuite,
        candidateProvider: { [psk] in
            [PskCandidate(psk: psk, category: pskCategory, requiredServerId: nil)]
        },
        clientHelloPayload: ClientHelloPayload(
            name: "Test Client",
            deviceInfo: nil,
            supportedPairMethods: [:],
            unpairedAccess: UnpairedAccessAdvertisement(enabled: unpairedAccessEnabled),
            supportedRoles: Array(roles),
            playerV1Support: nil,
            visualizerV1Support: nil
        ),
        unpairedAccessEnabled: unpairedAccessEnabled,
        scheduleNow: scheduleNow,
        scheduleSleep: scheduleSleep,
        audioSink: audioSink,
        artworkSink: artworkSink,
        visualizerSink: visualizerSink,
        emitRawAudio: emitRawAudio,
        artworkObserver: artworkObserver,
        validity: validity,
        advertisedCommands: advertisedCommands,
        roles: roles,
        initialVolume: initialVolume,
        initialMuted: initialMuted,
        initialArtworkState: initialArtworkState,
        initialVisualizerState: initialVisualizerState,
        requiredLeadTimeMs: requiredLeadTimeMs,
        minBufferMs: minBufferMs,
        clock: clock,
        engine: directEngine
    )
    if startConnection {
        await connection.start()
    }
    await server.startReadback()
    return EstablishedConnectionFixture(connection: connection, server: server, transport: transport)
}
