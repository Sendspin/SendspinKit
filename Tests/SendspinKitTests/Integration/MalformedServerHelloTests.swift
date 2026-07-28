import Foundation
@testable import SendspinKit
import Testing

/// Two defects met here: an unrecognized enum value failed the whole payload decode
/// (`decodeIfPresent` throws on a present-but-unknown value), and `route(text:)` only
/// logged the failure — so the handshake never completed and nothing timed it out.
///
/// The fixes are complementary: tolerate what we can reinterpret, fail loudly otherwise.
@MainActor
struct MalformedServerHelloTests {
    private func makeClient() throws -> SendspinClient {
        try SendspinClient(
            clientId: "malformed-hello-client",
            name: "Malformed Hello Client",
            roles: [.metadataV1]
        )
    }

    private func helloJSON(
        connectionReason: String = "playback",
        activeRoles: String = "[\"metadata@v1\"]",
        version: String = "1"
    ) -> String {
        """
        {"type":"server/hello","payload":{"server_id":"srv-1","name":"S","version":\(version),\
        "active_roles":\(activeRoles),"connection_reason":"\(connectionReason)"}}
        """
    }

    // MARK: - Forward compatibility

    /// A future spec value must not brick the client.
    @Test("an unrecognized connection_reason still completes the handshake")
    func unknownConnectionReasonStillConnects() async throws {
        let client = try makeClient()
        let mock = MockTransport()
        try await client.acceptConnection(mock)

        await mock.injectText(helloJSON(connectionReason: "some_future_reason"))

        #expect(
            await waitUntil { await MainActor.run { client.connectionState == .connected } },
            "an unknown connection_reason must not prevent the handshake completing"
        )
        #expect(client.currentServerId == "srv-1")
        #expect(
            client.currentConnectionReason == .playback,
            "an unrecognized reason should fall back to the default rather than throwing"
        )

        await client.disconnect()
    }

    /// Guards against the fallback swallowing real values.
    @Test("a recognized connection_reason is still decoded faithfully")
    func knownConnectionReasonIsPreserved() async throws {
        for (raw, expected) in [("discovery", ConnectionReason.discovery), ("playback", .playback)] {
            let client = try makeClient()
            let mock = MockTransport()
            try await client.acceptConnection(mock)

            await mock.injectText(helloJSON(connectionReason: raw))

            #expect(await waitUntil { await MainActor.run { client.connectionState == .connected } })
            #expect(client.currentConnectionReason == expected, "\(raw) must decode to \(expected)")

            await client.disconnect()
        }
    }

    // MARK: - Silence is also a failure

    /// The malformed-hello fixes only cover a hello that *arrives*. A server that completes
    /// the WebSocket upgrade and then says nothing parks the message loop in `nextFrame()`
    /// with nothing to time it out, leaving the client `.connecting` for the process's life.
    @Test("a server that never sends server/hello reaches a terminal state")
    func silentServerTimesOutTheHandshake() async throws {
        let transport = MockTransport()
        let engine = try AudioEngine(
            clock: ClockSynchronizer(),
            config: PlayerConfiguration(
                bufferCapacity: 100_000,
                supportedFormats: [AudioFormatSpec(codec: .pcm, channels: 2, sampleRate: 44_100, bitDepth: 16)]
            )
        )
        let connection = SendspinConnection(
            transport: transport,
            parsedHello: nil,
            clientHelloPayload: ClientHelloPayload(
                clientId: "silent-server-client",
                name: "Silent Server Client",
                deviceInfo: .current,
                version: 1,
                supportedRoles: [.playerV1],
                playerV1Support: nil,
                artworkV1Support: nil,
                visualizerV1Support: nil
            ),
            validity: SessionValidityToken(),
            advertisedCommands: [.setStaticDelay],
            roles: [.playerV1],
            handshakeTimeout: .milliseconds(100),
            engine: engine
        )

        await connection.start()
        // Deliberately inject nothing: the transport is open and silent.

        let terminal = await collectConnectionEvent(from: connection, timeout: .seconds(3)) {
            if case .disconnected = $0 {
                return true
            }
            return false
        }

        #expect(terminal != nil, "a silent server must produce a terminal event, not wedge")
        if case let .disconnected(reason) = terminal {
            #expect(
                reason == .handshakeTimeout,
                "the reason must name the timeout, not masquerade as a lost connection"
            )
        }
        #expect(await transport.disconnectCalled, "the half-open socket must be closed")
    }

    // MARK: - Loud failure instead of a silent wedge

    /// Pairing strict `active_roles` decoding with the loud-failure path below would make a
    /// single bad role string cost the whole connection — including the roles we *do*
    /// understand. Skipping the bad entry is the same forward-compat trade as
    /// `connection_reason`.
    @Test("a malformed active_roles entry is skipped, not fatal")
    func malformedRoleEntryIsSkipped() async throws {
        let client = try makeClient()
        let mock = MockTransport()
        try await client.acceptConnection(mock)

        // "metadata" has no `@version`, which `VersionedRole` rejects by design.
        await mock.injectText(helloJSON(activeRoles: "[\"metadata@v1\",\"metadata\"]"))

        #expect(
            await waitUntil { await MainActor.run { client.connectionState == .connected } },
            "one malformed role must not fail the handshake"
        )
        await client.disconnect()
    }

    /// The facade exposes no role list, so pin the leniency where it lives: the payload
    /// decode must keep the parseable entries and drop only the malformed one.
    @Test("decoding active_roles keeps the parseable entries and drops the rest")
    func activeRolesDecodeKeepsParseableEntries() throws {
        let json = """
        {"server_id":"srv-1","name":"S","version":1,\
        "active_roles":["metadata@v1","metadata","player@v1","@v1","artwork@"],\
        "connection_reason":"playback"}
        """
        let payload = try JSONDecoder().decode(ServerHelloPayload.self, from: Data(json.utf8))

        #expect(
            payload.activeRoles == [.metadataV1, .playerV1],
            "only the well-formed role@version entries may survive"
        )
    }

    /// A missing required field is the same class of failure and must also be terminal.
    @Test("a server/hello missing a required field disconnects instead of wedging")
    func serverHelloMissingRequiredFieldDisconnects() async throws {
        let client = try makeClient()
        let mock = MockTransport()
        try await client.acceptConnection(mock)

        // No `server_id`.
        await mock.injectText("""
        {"type":"server/hello","payload":{"name":"S","version":1,"active_roles":["metadata@v1"]}}
        """)

        #expect(await waitUntil { await mock.disconnectCalled })
        #expect(await waitUntil { await MainActor.run { client.connectionState == .disconnected } })
    }

    /// The loud-failure path must be scoped to the handshake; the loop must survive a bad
    /// ordinary message and keep processing.
    @Test("a malformed non-hello message does not disconnect and the loop keeps going")
    func malformedOrdinaryMessageDoesNotDisconnect() async throws {
        let client = try makeClient()
        let mock = MockTransport()
        try await client.acceptConnection(mock)
        await mock.injectText(helloJSON())
        #expect(await waitUntil { await MainActor.run { client.connectionState == .connected } })

        // Garbage `server/state`, then a well-formed one carrying observable metadata.
        await mock.injectText("""
        {"type":"server/state","payload":{"metadata":{"title":12345}}}
        """)
        await mock.injectText("""
        {"type":"server/state","payload":{"metadata":{"title":"Real Title","timestamp":1000}}}
        """)

        #expect(
            await waitUntil { await MainActor.run { client.currentMetadata?.title == "Real Title" } },
            "the message loop must survive one bad frame and still apply the next good one"
        )
        #expect(await !mock.disconnectCalled, "a bad ordinary message must not close the connection")
        #expect(client.connectionState == .connected)

        await client.disconnect()
    }
}
