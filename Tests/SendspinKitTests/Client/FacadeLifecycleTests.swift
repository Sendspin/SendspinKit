import Foundation
@testable import SendspinKit
import Testing

@MainActor
struct FacadeLifecycleTests {
    @Test("a disconnect while an accept handshakes prevents a later install")
    func acceptCancelledByDisconnectCannotInstall() async throws {
        let client = try makeTestClient()
        let transport = MockTransport()
        let server = MockNoiseServer(transport: transport, psk: .sentinel)

        let accepted = Task { try? await client.acceptConnection(transport) }
        #expect(await waitUntil { await transport.hasSentFrames })

        await client.disconnect(reason: .userRequest)
        // Complete the handshake after the disconnect: the accept's epoch guard must win.
        try await server.establishSession(activities: [.playback], activeRoles: [.playerV1])
        _ = await accepted.value

        #expect(client.connection == nil)
        #expect(await transport.disconnectCalled)
        #expect(client.connectionState == .disconnected)
    }

    @Test("a competing promotion supersedes a parked primary accept")
    func competingPromotionBumpsPrimaryEpoch() async throws {
        let client = try makeTestClient()

        let primary = MockTransport()
        let primaryServer = MockNoiseServer(transport: primary, psk: .sentinel)
        let primaryAccept = Task { try? await client.acceptConnection(primary) }
        #expect(await waitUntil { await primary.hasSentFrames })

        let competitor = MockTransport()
        let competitorServer = MockNoiseServer(transport: competitor, psk: .sentinel)
        let competitorAccept = Task { try? await client.acceptConnection(competitor) }
        try await competitorServer.establishSession(activities: [.playback], activeRoles: [.playerV1])
        _ = await competitorAccept.value
        #expect(await waitUntil { await MainActor.run { client.connectionState == .connected } })
        let promoted = client.connection

        try await primaryServer.establishSession(activities: [.playback], activeRoles: [.playerV1])
        _ = await primaryAccept.value

        #expect(client.connection === promoted)
        #expect(await primary.disconnectCalled)
        #expect(await competitor.disconnectCalled == false)
        await client.disconnect()
    }

    @Test("a disconnect during promotion teardown prevents the install")
    func disconnectDuringPromotionTeardownPreventsInstall() async throws {
        let client = try makeTestClient()

        let incumbent = MockTransport()
        let incumbentServer = MockNoiseServer(transport: incumbent, psk: .sentinel)
        async let incumbentAccepted: Void = client.acceptConnection(incumbent)
        try await incumbentServer.establishSession(activities: [], activeRoles: [])
        try await incumbentAccepted
        #expect(await waitUntil { await MainActor.run { client.connectionState == .connected } })

        let candidate = MockTransport()
        let candidateServer = MockNoiseServer(transport: candidate, psk: .sentinel)
        let replacementAccept = Task { try? await client.acceptConnection(candidate) }
        #expect(await waitUntil { await candidate.hasSentFrames })

        // The next-frame gate must hold promotion's goodbye, not a clock sample.
        let connection = try #require(client.connection)
        await connection.clockSyncTask?.cancel()
        await connection.clockSyncTask?.value
        try #require(await waitUntil { await !connection.outboundInFlight })
        await incumbent.parkNextOutboundFrame()
        try await candidateServer.establishSession(activities: [.playback], activeRoles: [.playerV1])
        try #require(await waitUntil { await incumbent.isOutboundFrameParked })
        #expect(client.connection == nil)

        await client.disconnect(reason: .userRequest)
        await incumbent.releaseOutboundFrame()
        _ = await replacementAccept.value

        #expect(client.connection == nil)
        #expect(await candidate.disconnectCalled)
        #expect(client.connectionState == .disconnected)
    }

    @Test("a failing parked accept cannot clobber a replacement session")
    func abandonedFailingAcceptCannotClobberReplacement() async throws {
        let client = try makeTestClient()

        let first = MockTransport()
        let firstAccept = Task { try? await client.acceptConnection(first) }
        #expect(await waitUntil { await first.hasSentFrames })

        let replacement = MockTransport()
        let replacementServer = MockNoiseServer(transport: replacement, psk: .sentinel)
        let replacementAccept = Task { try? await client.acceptConnection(replacement) }
        try await replacementServer.establishSession(activities: [.playback], activeRoles: [.playerV1])
        _ = await replacementAccept.value
        #expect(await waitUntil { await MainActor.run { client.connectionState == .connected } })
        let installed = client.connection

        // Fail the parked accept's handshake; its catch must not touch the winner.
        await first.finishStreams()
        _ = await firstAccept.value

        #expect(client.connection === installed)
        #expect(client.connectionState == .connected)
        #expect(await replacement.disconnectCalled == false)
        await client.disconnect()
    }

    @Test("Init refusal reaches the public connect error", arguments: ServerErrorReason.allCases)
    func initRefusalReachesApp(reason: ServerErrorReason) async throws {
        let client = try makeTestClient()
        let transport = MockTransport()
        await transport.injectText(
            "{\"type\":\"\(ServerErrorMessage.typeString)\",\"payload\":{\"reason\":\"\(reason.rawValue)\"}}"
        )
        await #expect(throws: SendspinClientError.connectionRefused(reason)) {
            try await client.acceptConnection(transport)
        }
        #expect(client.connection == nil)
        #expect(client.connectionState == .disconnected)
        #expect(await transport.disconnectCalled)
        await client.close()
    }

    @Test("close() during a paused accept terminates without installing")
    func closeDuringPausedAcceptTerminates() async throws {
        let client = try makeTestClient()
        let transport = MockTransport()

        let accepted = Task { try await client.acceptConnection(transport) }
        #expect(await waitUntil { await transport.hasSentFrames })

        await client.close()
        await #expect(throws: TerminatedError.self) { try await accepted.value }

        #expect(client.connection == nil)
        #expect(client.connectionState == .disconnected)
    }
}
