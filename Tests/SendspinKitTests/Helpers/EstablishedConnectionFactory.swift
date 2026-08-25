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

/// Construct a connection actor from a complete encrypted session. This is the
/// direct-connection counterpart to `connectClient`: the mock peer performs the
/// real cleartext and Noise handshake, then transfers its channel to the actor.
func makeEstablishedConnection(
    transport suppliedTransport: MockTransport? = nil,
    clock: any ClockSyncProtocol = ClockSynchronizer(),
    activities: Set<Activity> = [],
    activeRoles: Set<VersionedRole> = [.playerV1],
    psk: Psk = .sentinel,
    pskCategory: PskCategory = .sentinel,
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
        unpairedAccessEnabled: unpairedAccessEnabled,
        audioSink: audioSink,
        artworkSink: artworkSink,
        visualizerSink: visualizerSink,
        emitRawAudio: emitRawAudio,
        validity: validity,
        advertisedCommands: advertisedCommands,
        roles: roles,
        initialVolume: initialVolume,
        initialMuted: initialMuted,
        clock: clock,
        engine: directEngine
    )
    guard startConnection else {
        return EstablishedConnectionFixture(connection: connection, server: server, transport: transport)
    }
    await connection.start()
    try await server.sendJSON(#"{"type":"server/hello","payload":{"name":"Direct Test Server"}}"#)
    _ = try await server.nextClientJSON()
    let activate = ServerActivateMessage(payload: ServerActivatePayload(
        activities: Array(activities),
        activeRoles: Array(activeRoles)
    ))
    let activateData = try JSONEncoder().encode(activate)
    guard let activateText = String(data: activateData, encoding: .utf8) else {
        throw MockNoiseServer.Failure.malformedClientMessage
    }
    try await server.sendJSON(activateText)
    return EstablishedConnectionFixture(connection: connection, server: server, transport: transport)
}
