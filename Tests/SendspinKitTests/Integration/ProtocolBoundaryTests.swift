import Foundation
@testable import SendspinKit
import Testing

/// Protocol-boundary coverage against a real encrypted ``MockNoiseServer``.
@Suite("Protocol boundaries", .serialized, .timeLimit(.minutes(1)))
@MainActor
struct ProtocolBoundaryTests {
    @Test("a fragmented send completes under the old key before re-handshake reply, while a queued send is rejected")
    func fragmentedSendIsFencedByRehandshake() async throws {
        let transport = MockTransport()
        let fixture = try await makeEstablishedConnection(
            transport: transport,
            activities: [.playback],
            activeRoles: [],
            roles: []
        )
        let connection = fixture.connection
        let server = fixture.server

        // Remove the sampler so it cannot compete with the ordered send sequence.
        #expect(await waitUntil { await connection.clockSyncTask != nil }, "clock-sync task handle must appear before cancel")
        await connection.clockSyncTask?.cancel()
        await connection.clockSyncTask?.value
        #expect(await waitUntil { await !connection.outboundInFlight }, "initial clock samples must drain")

        await transport.parkNextOutboundFrame()
        let fragmented = Task { () -> Result<Void, Error> in
            do {
                try await connection.send(clientMessage: ProtocolBoundaryOutboundMessage(
                    kind: .fragmented,
                    note: String(repeating: "f", count: NoiseChannel.maxSinglePayload + 2_000)
                ))
                return .success(())
            } catch {
                return .failure(error)
            }
        }
        #expect(await waitUntil { await transport.isOutboundFrameParked })

        // This sender is queued before message 1 and checks the gate after the fence.
        let queued = Task { () -> Result<Void, Error> in
            do {
                try await connection.send(clientMessage: ProtocolBoundaryOutboundMessage(
                    kind: .queued,
                    note: "must-not-cross-rehandshake"
                ))
                return .success(())
            } catch {
                return .failure(error)
            }
        }
        #expect(await waitUntil { await connection.outboundWaiters.count == 1 })

        try await server.beginRehandshake(to: .sentinel)
        #expect(await waitUntil { await connection.isRehandshakeInProgress })
        await transport.releaseOutboundFrame()

        let fragmentedResult = await fragmented.value
        #expect((try? fragmentedResult.get()) != nil)
        #expect(
            await waitUntil {
                await server.decryptedMessages.contains { message in
                    protocolBoundaryOutboundKind(in: message) == .fragmented
                }
            },
            "the complete fragmented message must arrive before the key swap"
        )

        let queuedResult = await queued.value
        #expect((try? queuedResult.get()) == nil, "a sender queued before message 1 must not cross the re-handshake gate")
        #expect(await waitUntil { await server.rehandshakeComplete })

        let observedMessages = await server.decryptedMessages
        let fragmentedIndex = try #require(observedMessages.firstIndex {
            protocolBoundaryOutboundKind(in: $0) == .fragmented
        })
        let rehandshakeReplyIndex = try #require(observedMessages.firstIndex {
            guard $0.first == NoiseFrameType.json else { return false }
            return SendspinEncoding.messageType(of: Data($0.dropFirst())) == NoiseHandshakeMessage.typeString
        })
        #expect(fragmentedIndex < rehandshakeReplyIndex, "the complete old-key message must precede the noise reply")
        let observedKinds = observedMessages.compactMap(protocolBoundaryOutboundKind)
        #expect(observedKinds == [.fragmented], "only the complete old-key message may reach the peer")
        await connection.shutdown()
    }

    @Test("an encrypted null state immediately clears a pending future metadata snapshot")
    func nullClearsPendingFutureMetadataImmediately() async throws {
        let schedule = ProtocolBoundaryManualTime(now: 0)
        let clock = ProtocolBoundaryIdentityClock()
        let fixture = try await makeEstablishedConnection(
            clock: clock,
            activities: [.playback],
            activeRoles: [],
            roles: [.metadataV1],
            scheduleNow: { schedule.now },
            scheduleSleep: { duration in try await Task.sleep(for: duration) }
        )
        let server = fixture.server
        let connection = fixture.connection

        try await server.sendActivation(activities: [.playback], activeRoles: [.metadataV1])
        #expect(await waitUntil { await connection.activeRoles == [.metadataV1] })

        try await server.sendJSON(#"{"type":"server/state","payload":{"metadata":null}}"#)
        #expect(await waitUntil { await connection.currentMetadata == nil })

        try await server.sendActivation(activities: [.playback], activeRoles: [])
        #expect(await waitUntil { await connection.activeRoles.isEmpty })
        try await server.sendActivation(activities: [.playback], activeRoles: [.metadataV1])
        #expect(await waitUntil { await connection.activeRoles == [.metadataV1] })

        try await server.sendJSON(#"{"type":"server/state","payload":{"metadata":{"timestamp":1000,"title":"pending"}}}"#)
        #expect(await waitUntil { await connection.metadataPending != nil })

        // Null is a clear, not omission, even for the first state after reactivation.
        try await server.sendJSON(#"{"type":"server/state","payload":{"metadata":null}}"#)
        #expect(await waitUntil { await connection.metadataPending == nil })
        #expect(await connection.currentMetadata == nil)
        #expect(await connection.metadataScheduleTask == nil)
        await connection.shutdown()
    }

    @Test("metadata, color, and controller roles do not add objects to client/state")
    func serverStateRolesRemainAbsentFromClientState() async throws {
        let fixture = try await makeEstablishedConnection(
            activities: [.playback],
            activeRoles: [],
            roles: [.metadataV1, .colorV1, .controllerV1]
        )
        let server = fixture.server
        let connection = fixture.connection
        #expect(await waitUntil { await connection.clockSyncTask != nil }, "clock-sync task handle must appear before cancel")
        await connection.clockSyncTask?.cancel()
        await connection.clockSyncTask?.value
        #expect(await waitUntil { await !connection.outboundInFlight }, "initial clock samples must drain")

        try await server.sendActivation(
            activities: [.playback],
            activeRoles: [.metadataV1, .colorV1, .controllerV1]
        )
        #expect(
            await waitUntil {
                await connection.activeRoles == [.metadataV1, .colorV1, .controllerV1]
            }
        )
        #expect(
            await waitUntil {
                await clientStateSnapshots(server).contains(where: {
                    $0.payload.player == nil && $0.payload.artwork == nil && $0.payload.visualizer == nil
                })
            },
            "the initial non-player client/state must reach the peer before role removal"
        )
        let initialState = try #require(
            await clientStateSnapshots(server).reversed().first(where: {
                $0.payload.player == nil && $0.payload.artwork == nil && $0.payload.visualizer == nil
            })
        )
        let beforeRemoval = await server.clientJSONMessages(ofType: ClientStateMessage.typeString).count

        try await server.sendActivation(activities: [.playback], activeRoles: [])
        #expect(await waitUntil { await connection.activeRoles.isEmpty })
        #expect(
            await waitUntil {
                let states = await clientStateSnapshots(server)
                return states.count > beforeRemoval && states.dropFirst(beforeRemoval).contains(where: {
                    $0.payload.player == nil && $0.payload.artwork == nil && $0.payload.visualizer == nil
                })
            },
            "the removal client/state must reach the peer before recording the reactivation baseline"
        )
        let baseline = await server.clientJSONMessages(ofType: ClientStateMessage.typeString).count

        try await server.sendActivation(
            activities: [.playback],
            activeRoles: [.metadataV1, .colorV1, .controllerV1]
        )
        #expect(await waitUntil {
            await connection.activeRoles == [.metadataV1, .colorV1, .controllerV1]
        })

        #expect(
            await waitUntil {
                let states = await clientStateSnapshots(server)
                return states.count > baseline && states.dropFirst(baseline).contains(where: { $0 == initialState })
            },
            "reactivation must deliver a fresh exact non-player client/state snapshot"
        )
        await connection.shutdown()
    }

    @Test("player reactivation publishes a player state-bearing client/state snapshot")
    func playerRoleReactivationPublishesPlayerState() async throws {
        let fixture = try await makeEstablishedConnection(
            activities: [.playback],
            activeRoles: [],
            roles: [.playerV1]
        )
        let server = fixture.server
        let connection = fixture.connection
        #expect(await waitUntil { await connection.clockSyncTask != nil }, "clock-sync task handle must appear before cancel")
        await connection.clockSyncTask?.cancel()
        await connection.clockSyncTask?.value
        #expect(await waitUntil { await !connection.outboundInFlight }, "initial clock samples must drain")

        try await server.sendActivation(activities: [.playback], activeRoles: [.playerV1])
        #expect(await waitUntil { await connection.activeRoles == [.playerV1] })
        #expect(
            await waitUntil {
                await clientStateSnapshots(server).contains(where: { $0.payload.player != nil })
            },
            "the initial player client/state must reach the peer before role removal"
        )
        let initialState = try #require(
            await clientStateSnapshots(server).reversed().first(where: { $0.payload.player != nil })
        )
        let beforeRemoval = await server.clientJSONMessages(ofType: ClientStateMessage.typeString).count

        try await server.sendActivation(activities: [.playback], activeRoles: [])
        #expect(await waitUntil { await connection.activeRoles.isEmpty })
        #expect(
            await waitUntil {
                let states = await clientStateSnapshots(server)
                return states.count > beforeRemoval && states.dropFirst(beforeRemoval).contains(where: {
                    $0.payload.player == nil
                })
            },
            "the removal client/state must reach the peer before recording the reactivation baseline"
        )
        let baseline = await server.clientJSONMessages(ofType: ClientStateMessage.typeString).count

        try await server.sendActivation(activities: [.playback], activeRoles: [.playerV1])
        #expect(await waitUntil { await connection.activeRoles == [.playerV1] })

        #expect(
            await waitUntil {
                let states = await clientStateSnapshots(server)
                return states.count > baseline && states.dropFirst(baseline).contains(where: { $0 == initialState })
            },
            "reactivation must deliver a fresh exact player client/state snapshot"
        )
        #expect(await connection.playerStateSent)
        await connection.shutdown()
    }

    @Test("controller volume round-trips the server's integer group value without client-side averaging")
    func controllerVolumeIsServerAuthoritativeInteger() async throws {
        let client = try makeTestClient(roles: [.controllerV1])
        let server = try await connectClient(
            client,
            activeRoles: [.controllerV1],
            activities: [.playback]
        )

        await server.injectText(#"{"type":"server/state","payload":{"controller":{"supported_commands":["volume"],"volume":37,"muted":false}}}"#)
        #expect(await waitUntil { await MainActor.run { client.currentControllerState?.volume == 37 } })

        let baseline = await server.clientJSONMessages(ofType: ClientCommandMessage.typeString).count
        try await client.setGroupVolume(42)
        #expect(await waitUntil {
            await server.clientJSONMessages(ofType: ClientCommandMessage.typeString).count > baseline
        })
        let commandData = try #require(await server.clientJSONMessages(ofType: ClientCommandMessage.typeString).last)
        let commandObject = try #require(JSONSerialization.jsonObject(with: commandData) as? [String: Any])
        let payload = try #require(commandObject["payload"] as? [String: Any])
        let controller = try #require(payload["controller"] as? [String: Any])
        #expect(controller["command"] as? String == "volume")
        #expect(controller["volume"] as? Int == 42)

        // A later server/state value remains authoritative for the group.
        await server.injectText(#"{"type":"server/state","payload":{"controller":{"supported_commands":["volume"],"volume":37,"muted":false}}}"#)
        #expect(await waitUntil { await MainActor.run { client.currentControllerState?.volume == 37 } })
        await client.disconnect()
    }
}

private func clientStateSnapshots(_ server: MockNoiseServer) async -> [ClientStateMessage] {
    await server.clientJSONMessages(ofType: ClientStateMessage.typeString).compactMap {
        try? JSONDecoder().decode(ClientStateMessage.self, from: $0)
    }
}

private func protocolBoundaryOutboundKind(in message: Data) -> ProtocolBoundaryOutboundKind? {
    guard message.first == NoiseFrameType.json else { return nil }
    guard let decoded = try? JSONDecoder().decode(
        ProtocolBoundaryOutboundMessage.self,
        from: Data(message.dropFirst())
    ) else { return nil }
    return decoded.kind
}

private enum ProtocolBoundaryOutboundKind: String, Codable, Sendable {
    case fragmented
    case queued
}

private struct ProtocolBoundaryOutboundMessage: Codable, Sendable {
    let kind: ProtocolBoundaryOutboundKind
    let note: String
}

private final class ProtocolBoundaryManualTime: @unchecked Sendable {
    var now: Int64

    init(now: Int64) {
        self.now = now
    }
}

private actor ProtocolBoundaryIdentityClock: ClockSyncProtocol {
    var hasSynced: Bool {
        false
    }

    func processServerTime(
        clientTransmitted _: Int64,
        serverReceived _: Int64,
        serverTransmitted _: Int64,
        clientReceived _: Int64
    ) {}

    func serverTimeToLocal(_ serverTime: Int64) -> Int64 {
        serverTime
    }

    func localTimeToServer(_ localTime: Int64) -> Int64 {
        localTime
    }

    func snapshot() -> TimeFilterSnapshot? {
        nil
    }

    func diagnosticSnapshot() -> ClockSynchronizer.DiagnosticSnapshot? {
        nil
    }
}
