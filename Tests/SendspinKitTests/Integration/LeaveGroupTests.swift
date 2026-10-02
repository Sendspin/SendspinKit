import Foundation
@testable import SendspinKit
import Testing

@Suite("Client leave")
@MainActor
struct LeaveGroupTests {
    @Test("leave sends encrypted client/leave with an empty payload without requiring controller")
    func leaveSendsExactEncryptedMessageWithoutStateFlap() async throws {
        let client = try makeTestClient(roles: [.metadataV1])
        let server = try await connectClient(client, activeRoles: [.metadataV1])
        try await establishClockSync(client, via: server)

        let stateCountBefore = await server.clientJSONMessages(ofType: ClientStateMessage.typeString).count
        try await client.leaveGroup()

        #expect(await waitUntil(timeout: .seconds(3)) {
            await server.clientJSONMessages(ofType: ClientLeaveMessage.typeString).count == 1
        })
        let leaveData = try #require(await server.clientJSONMessages(ofType: ClientLeaveMessage.typeString).first)
        let leaveObject = try #require(JSONSerialization.jsonObject(with: leaveData) as? [String: Any])
        let leavePayload = try #require(leaveObject["payload"] as? [String: Any])
        #expect(leaveObject["type"] as? String == ClientLeaveMessage.typeString)
        #expect(leavePayload.isEmpty)
        #expect(
            await server.clientJSONMessages(ofType: ClientStateMessage.typeString).count == stateCountBefore,
            "leave must not publish an availability or client/state flap"
        )

        await client.disconnect()
    }

    @Test("leave does not invent or clear local group state while unavailable")
    func leavePreservesGroupStateWhileExternalSourceIsActive() async throws {
        let client = try makeTestClient(roles: [.metadataV1])
        let server = try await connectClient(client, activeRoles: [.metadataV1])
        try await establishClockSync(client, via: server)
        try await server.sendJSON(#"{"type":"group/update","payload":{"playback_state":"playing","group_id":"group-1","group_name":"Living Room"}}"#)
        #expect(await waitUntil {
            await MainActor.run { client.currentGroup?.groupId == "group-1" }
        })

        try await client.enterExternalSource()
        #expect(client.clientOperationalState == .externalSource)
        let groupBefore = client.currentGroup
        let stateCountBeforeLeave = await server.clientJSONMessages(ofType: ClientStateMessage.typeString).count

        try await client.leaveGroup()

        #expect(await waitUntil(timeout: .seconds(3)) {
            await server.clientJSONMessages(ofType: ClientLeaveMessage.typeString).count == 1
        })
        #expect(client.currentGroup == groupBefore)
        #expect(client.clientOperationalState == .externalSource)
        #expect(
            await server.clientJSONMessages(ofType: ClientStateMessage.typeString).count == stateCountBeforeLeave,
            "leave must not toggle unavailable client/state"
        )

        await client.disconnect()
    }

    @Test("leave is unavailable while disconnected")
    func leaveRequiresConnection() async throws {
        let client = try makeTestClient(roles: [.metadataV1])

        await #expect(throws: SendspinClientError.notConnected) {
            try await client.leaveGroup()
        }
    }

    @Test("leave is unavailable after disconnect")
    func leaveRejectsStoppedConnection() async throws {
        let client = try makeTestClient(roles: [.metadataV1])
        _ = try await connectClient(client, activeRoles: [.metadataV1])
        await client.disconnect()

        await #expect(throws: SendspinClientError.notConnected) {
            try await client.leaveGroup()
        }
    }

    @Test("leave is gated during re-handshake")
    func leaveRequiresCompletedRehandshake() async throws {
        let client = try makeTestClient(roles: [.metadataV1])
        let server = try await connectClient(client, activeRoles: [.metadataV1])
        let connection = try #require(client.connection)

        try await server.beginRehandshake(to: .sentinel)
        #expect(await waitUntil { await connection.isRehandshakeInProgress })
        await #expect(throws: SendspinClientError.handshakeIncomplete) {
            try await client.leaveGroup()
        }
        #expect(await server.clientJSONMessages(ofType: ClientLeaveMessage.typeString).isEmpty)

        await client.disconnect()
    }

    @Test("queued leave is rejected after graceful shutdown begins")
    func queuedLeaveDoesNotFollowGoodbye() async throws {
        let client = try makeTestClient(roles: [.metadataV1])
        let server = try await connectClient(client, activeRoles: [.metadataV1])
        let connection = try #require(client.connection)

        await connection.clockSyncTask?.cancel()
        await connection.clockSyncTask?.value
        try #require(await waitUntil { await !connection.outboundInFlight })

        await server.parkNextOutboundFrame()
        let firstSend = Task { () -> Result<Void, Error> in
            do {
                try await connection.send(
                    clientMessage: ClientTimeMessage(
                        payload: ClientTimePayload(clientTransmitted: MonotonicClock.nowMicroseconds())
                    )
                )
                return .success(())
            } catch {
                return .failure(error)
            }
        }
        #expect(await waitUntil { await server.isOutboundFrameParked })

        let leave = Task { () -> Result<Void, Error> in
            do {
                try await client.leaveGroup()
                return .success(())
            } catch {
                return .failure(error)
            }
        }
        #expect(await waitUntil { await connection.outboundWaiters.count == 1 })

        let disconnect = Task { await client.disconnect(reason: .userRequest) }
        #expect(await waitUntil { await connection.lifecycle == .shuttingDown })

        await server.releaseOutboundFrame()
        let firstResult = await firstSend.value
        #expect((try? firstResult.get()) != nil)

        let leaveResult = await leave.value
        guard case let .failure(error) = leaveResult else {
            Issue.record("leave must be rejected once graceful shutdown begins")
            await disconnect.value
            return
        }
        guard case SendspinClientError.notConnected = error else {
            Issue.record("queued leave failed with an unexpected error: \(error)")
            await disconnect.value
            return
        }

        await disconnect.value
        #expect(await server.clientJSONMessages(ofType: ClientLeaveMessage.typeString).isEmpty)
        #expect(await server.clientJSONMessages(ofType: ClientGoodbyeMessage.typeString).count == 1)
    }

    @Test("leave surfaces encrypted transport failure")
    func leaveSurfacesSendFailure() async throws {
        let client = try makeTestClient(roles: [.metadataV1])
        let server = try await connectClient(client, activeRoles: [.metadataV1])
        await server.transport.setShouldFailOnSend(true)

        await #expect(throws: SendspinClientError.self) {
            try await client.leaveGroup()
        }
        #expect(await server.clientJSONMessages(ofType: ClientLeaveMessage.typeString).isEmpty)
        #expect(await waitUntil { await server.transport.disconnectCalled })
    }
}
