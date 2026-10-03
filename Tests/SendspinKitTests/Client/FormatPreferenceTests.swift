import Foundation
@testable import SendspinKit
import Testing

@Suite("Format preference")
@MainActor
struct FormatPreferenceTests {
    // swiftlint:disable:next force_try
    private let fallback = try! AudioFormatSpec(codec: .pcm, channels: 2, sampleRate: 44_100, bitDepth: 16)
    // swiftlint:disable:next force_try
    private let native = try! AudioFormatSpec(codec: .flac, channels: 2, sampleRate: 48_000, bitDepth: 24)

    @Test("Opus host preferences ignore bit depth when matching the catalog")
    func opusPreferenceIgnoresBitDepth() async throws {
        let opus = try AudioFormatSpec(codec: .opus, channels: 2, sampleRate: 48_000, bitDepth: 16)
        let client = try makeClient(formats: [opus, fallback])
        let server = try await connect(client)
        try await client.setPlayerFormatPreference(
            codec: .opus,
            channels: opus.channels,
            sampleRate: opus.sampleRate,
            bitDepth: 7
        )
        #expect(await waitUntil { await states(server).last?.payload.player?.format == opus })
        #expect(await states(server).last?.payload.player?.format?.bitDepth == opus.bitDepth)
        await client.disconnect()
    }

    @Test("setting a preference publishes client/state.player.format")
    func settingPreferencePublishesWireFormat() async throws {
        let client = try makeClient(formats: [fallback, native])
        let server = try await connect(client)
        let before = await states(server).count
        try await client.setPlayerFormatPreference(native)
        #expect(await waitUntil(timeout: .seconds(3)) { await states(server).count > before })
        let state = try #require(await states(server).last)
        #expect(state.payload.player?.format == native)
        #expect(client.preferredPlayerFormat == native)
        // Mutation claim: suppressing the state publication or omitting player.format fails this wire assertion.
        await client.disconnect()
    }

    @Test("a mid-stream preference change republishes the new format")
    func midStreamPreferenceChangeRepublishes() async throws {
        let client = try makeClient(formats: [fallback, native])
        let server = try await connect(client)
        try await server.injectText(streamStart(format: fallback))
        #expect(await waitUntil(timeout: .seconds(3)) { await client.connection?.announcedPlayerStream?.format == fallback })
        let before = await states(server).count
        try await client.setPlayerFormatPreference(native)
        #expect(await waitUntil(timeout: .seconds(3)) { await states(server).count > before })
        #expect(await states(server).last?.payload.player?.format == native)
        await client.disconnect()
    }

    @Test("output route adaptation publishes a preference and arms a deadline")
    func routeAdaptationPublishesAndArmsDeadline() async throws {
        let provider = AudioOutputCapabilityService(initialSnapshot: output(44_100, "Initial"), platformMonitor: InertAudioOutputPlatformMonitor())
        let client = try makeClient(formats: [fallback, native], provider: provider, settle: .zero)
        let server = try await connect(client)
        try await server.injectText(streamStart(format: fallback))
        #expect(await waitUntil(timeout: .seconds(3)) { await client.connection?.announcedPlayerStream?.format == fallback })
        await provider.update(output(48_000, "Changed route"))
        #expect(await waitUntil(timeout: .seconds(3)) { await states(server).contains { $0.payload.player?.format == native } })
        #expect(await client.connection?.pendingOutputFormatRequest?.target == native)
        #expect(client.currentOutputFormatStatus?.state == .requesting(native))
        // Mutation claim: removing automatic route adaptation or deadline arming fails pending/status assertions.
        await client.disconnect()
        await provider.stopMonitoring()
    }

    @Test("route reversal reopens identical announcements without an engine transition")
    func identicalAnnouncementReopensMatchingRouteWithoutCommand() async throws {
        let provider = AudioOutputCapabilityService(
            initialSnapshot: output(44_100, "Initial"),
            platformMonitor: InertAudioOutputPlatformMonitor()
        )
        let client = try makeClient(formats: [fallback, native], provider: provider, settle: .zero)
        let server = try await connect(client)
        try await server.injectText(streamStart(format: fallback))
        #expect(await waitUntil(timeout: .seconds(3)) { await client.connection?.announcedPlayerStream?.format == fallback })

        await provider.update(output(48_000, "Changed route"))
        #expect(await waitUntil(timeout: .seconds(3)) { await client.connection?.routeInvalidationPending == true })
        await provider.update(output(44_100, "Returned route"))
        #expect(await waitUntil(timeout: .seconds(3)) { await client.connection?.settledOutputSampleRate == 44_100 })
        #expect(await client.connection?.routeInvalidationPending == true)

        try await server.injectText(streamStart(format: fallback))
        let engine = try #require(client.connection?.audioEngineForTesting)
        #expect(await waitUntil { await client.connection?.routeInvalidationPending == false })
        #expect(await engine.isRouteInvalidatedForTesting() == false)
        await server.injectText(#"{"type":"stream/end","payload":{"roles":["player"]}}"#)
        #expect(await waitUntil { await engine.appliedCommandKinds().contains(.streamEnd) })
        #expect(
            await engine.appliedCommandKinds().contains(.routeInvalidatedFormatChange) == false,
            "a matching returned route reopens ingress without a destructive transition"
        )
        #expect(await engine.appliedCommandKinds().filter { $0 == .streamStart }.count == 1)
        #expect(await engine.appliedCommandKinds().contains(.formatChange) == false)
        await client.disconnect()
        await provider.stopMonitoring()
    }

    @Test("identical route-request answers rebuild once while the route mismatches")
    func identicalAnnouncementWaitsForRouteRequest() async throws {
        let provider = AudioOutputCapabilityService(initialSnapshot: output(44_100, "Initial"), platformMonitor: InertAudioOutputPlatformMonitor())
        let client = try makeClient(formats: [fallback, native], provider: provider, settle: .zero)
        let server = try await connect(client)
        try await establishClockSync(client, via: server)
        try await server.injectText(streamStart(format: fallback))
        let connection = try #require(client.connection)
        try #require(await waitUntil { await connection.audioEngineForTesting.appliedCommandKinds().contains(.streamStart) })
        await provider.update(output(48_000, "New route"))
        try #require(await waitUntil { await connection.pendingOutputFormatRequest != nil })
        let engine = connection.audioEngineForTesting
        try await server.injectText(streamStart(format: fallback))
        try #require(await waitUntil { await connection.pendingOutputFormatRequest == nil })
        try #require(await waitUntil { await engine.appliedCommandKinds().filter { $0 == .routeInvalidatedFormatChange }.count == 1 })
        #expect(await engine.isRouteInvalidatedForTesting() == false)
        #expect(await engine.appliedCommandKinds().filter { $0 == .routeInvalidatedFormatChange }.count == 1)
        await client.disconnect()
        await provider.stopMonitoring()
    }

    @Test("identical announcements rebuild once when no route request is possible")
    func identicalAnnouncementRebuildsWithoutRouteRequest() async throws {
        let provider = AudioOutputCapabilityService(initialSnapshot: output(44_100, "Initial"), platformMonitor: InertAudioOutputPlatformMonitor())
        let client = try makeClient(formats: [fallback], provider: provider, settle: .zero)
        let server = try await connect(client)
        try await server.injectText(streamStart(format: fallback))
        let connection = try #require(client.connection)
        try await requireOutputCondition("no-request initial stream applied") {
            await connection.audioEngineForTesting.appliedCommandKinds().contains(.streamStart)
        }
        await provider.update(output(48_000, "Unsupported route"))
        try await requireOutputCondition("unsupported route settled") { await connection.settledOutputSampleRate == 48_000 }
        let engine = connection.audioEngineForTesting
        #expect(await connection.pendingOutputFormatRequest == nil)
        try await server.injectText(streamStart(format: fallback))
        #expect(await waitUntil { await engine.appliedCommandKinds().filter { $0 == .routeInvalidatedFormatChange }.count == 1 })
        #expect(await engine.isRouteInvalidatedForTesting() == false)
        #expect(await engine.appliedCommandKinds().filter { $0 == .routeInvalidatedFormatChange }.count == 1)
        await client.disconnect()
        await provider.stopMonitoring()
    }

    @Test("route request timeout rebuilds once and reopens ingress")
    func routeRequestTimeoutRebuildsOnce() async throws {
        let provider = AudioOutputCapabilityService(initialSnapshot: output(44_100, "Initial"), platformMonitor: InertAudioOutputPlatformMonitor())
        let client = try makeClient(formats: [fallback, native], provider: provider, settle: .zero, requestTimeout: .milliseconds(100))
        let server = try await connect(client)
        try await server.injectText(streamStart(format: fallback))
        #expect(await waitUntil { await client.connection?.announcedPlayerStream?.format == fallback })
        let connection = try #require(client.connection)
        let engine = connection.audioEngineForTesting
        try #require(await waitUntil { await engine.appliedCommandKinds().contains(.streamStart) })
        await provider.update(output(48_000, "Changed route"))
        // Wire history retains the request even when its deadline fires before this task resumes.
        #expect(await waitUntil { await states(server).contains { $0.payload.player?.format == native } })
        #expect(await waitUntil { await engine.appliedCommandKinds().filter { $0 == .routeInvalidatedFormatChange }.count == 1 })
        #expect(await connection.playerStartGeneration == 2)
        #expect(await connection.pendingOutputFormatRequest == nil)
        #expect(await engine.isRouteInvalidatedForTesting() == false)
        #expect(await connection.routeInvalidationPending == false)
        #expect(await engine.appliedCommandKinds().filter { $0 == .routeInvalidatedFormatChange }.count == 1)
        await client.disconnect()
        await provider.stopMonitoring()
    }

    @Test("automatic deadline expiry publishes truthful fallback status")
    func automaticDeadlineExpiryPublishesFallbackStatus() async throws {
        let provider = AudioOutputCapabilityService(initialSnapshot: output(44_100, "Initial"), platformMonitor: InertAudioOutputPlatformMonitor())
        let client = try makeClient(formats: [fallback, native], provider: provider, settle: .zero, requestTimeout: .zero)
        let server = try await connect(client)
        try await server.injectText(streamStart(format: fallback))
        #expect(await waitUntil(timeout: .seconds(3)) { await client.connection?.announcedPlayerStream?.format == fallback })
        await provider.update(output(48_000, "Changed route"))
        #expect(await waitUntil(timeout: .seconds(3)) { await states(server).contains { $0.payload.player?.format == native } })
        #expect(await waitUntil(timeout: .seconds(3)) { await client.currentOutputFormatStatus?.state == .activeFallback(fallback) })
        #expect(await client.connection?.pendingOutputFormatRequest == nil)
        // Mutation claim: a false active-native/preferred status or missing timeout fails the fallback status assertion.
        await client.disconnect()
        await provider.stopMonitoring()
    }

    @Test("no matching preference leaves facade and connection mirrors unchanged")
    func noMatchingFormatRollsBackMirrors() async throws {
        let client = try makeClient(formats: [fallback, native])
        let server = try await connect(client)
        try await client.setPlayerFormatPreference(fallback)
        let before = client.preferredPlayerFormat
        await #expect(throws: OutputFormatError.noMatchingFormat) {
            try await client.setPlayerFormatPreference(codec: .opus)
        }
        #expect(client.preferredPlayerFormat == before)
        #expect(await client.connection?.preferredPlayerFormat == before)
        #expect(await states(server).last?.payload.player?.format == before)
        await client.disconnect()
    }

    @Test("format preference survives re-handshake and reconnect")
    func preferenceSurvivesRehandshakeAndReconnect() async throws {
        let client = try makeClient(formats: [fallback, native])
        let server = try await connect(client)
        try await client.setPlayerFormatPreference(native)
        #expect(await waitUntil(timeout: .seconds(3)) { await states(server).last?.payload.player?.format == native })

        try await server.beginRehandshake(to: .sentinel)
        #expect(await waitUntil(timeout: .seconds(3)) { await server.rehandshakeComplete })
        try await server.sendActivation(activities: [.playback], activeRoles: [.playerV1])
        #expect(await waitUntil(timeout: .seconds(3)) { await states(server).last?.payload.player?.format == native })

        await client.disconnect()
        let second = try await connect(client)
        try await establishClockSync(client, via: second)
        #expect(await waitUntil(timeout: .seconds(3)) { await states(second).last?.payload.player?.format == native })
        // Mutation claim: dropping preference transfer at either re-handshake or reconnect fails the two fresh-session wire assertions.
        await client.disconnect()
    }

    private func makeClient(
        formats: [AudioFormatSpec],
        provider: AudioOutputCapabilityService = AudioOutputCapabilityService(platformMonitor: InertAudioOutputPlatformMonitor()),
        settle: Duration = .milliseconds(250),
        requestTimeout: Duration = .seconds(3)
    ) throws -> SendspinClient {
        try SendspinClient(
            identity: .generate(), name: "Format Preference", roles: [.playerV1],
            playerConfig: PlayerConfiguration(bufferCapacity: 1_024, supportedFormats: formats, volumeMode: .none),
            audioOutputCapabilityProvider: provider,
            outputSettleInterval: settle, outputRequestTimeout: requestTimeout,
            audioOutputFactory: { _, _ in NoOpAudioOutput() }
        )
    }

    private func connect(_ client: SendspinClient) async throws -> MockNoiseServer {
        let transport = MockTransport()
        let server = MockNoiseServer(transport: transport, psk: .sentinel)
        async let accepted: Void = client.acceptConnection(transport)
        try await server.establishSession(activities: [.playback], activeRoles: [.playerV1])
        try await accepted
        try await waitForState(client, expected: .connected, timeout: .seconds(3))
        return server
    }

    private func states(_ server: MockNoiseServer) async -> [ClientStateMessage] {
        await server.clientJSONMessages(ofType: ClientStateMessage.typeString).compactMap {
            try? JSONDecoder().decode(ClientStateMessage.self, from: $0)
        }
    }

    private func output(_ rate: Int, _ description: String) -> AudioOutputSnapshot {
        AudioOutputSnapshot(sampleRate: rate, reportedBitDepth: nil, diagnosticDescription: description)
    }

    private func streamStart(format: AudioFormatSpec) throws -> String {
        let message = StreamStartMessage(payload: StreamStartPayload(
            player: StreamStartPlayer(
                codec: format.codec.rawValue,
                sampleRate: format.sampleRate,
                channels: format.channels,
                bitDepth: format.bitDepth,
                codecHeader: nil
            ),
            artwork: nil, visualizer: nil
        ))
        return try #require(String(data: JSONEncoder().encode(message), encoding: .utf8))
    }
}
