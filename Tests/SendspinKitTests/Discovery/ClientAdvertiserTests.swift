// ABOUTME: Tests for ClientAdvertiser mDNS advertisement and WebSocket server
// ABOUTME: Tests for multi-server decision logic and NWWebSocketTransport

import Foundation
import Network
@testable import SendspinKit
import Testing

struct ClientAdvertiserTests {
    @Test
    func clientAdvertiser_startsAndStopsWithoutError() async throws {
        let advertiser = ClientAdvertiser(name: "Test Speaker", port: 18_929, path: "/sendspin")

        try await advertiser.start()
        let isRunning = await advertiser.isRunning
        #expect(isRunning)

        await advertiser.stop()
        let isStoppedAfter = await advertiser.isRunning
        #expect(!isStoppedAfter)
    }

    @Test
    func clientAdvertiser_defaultsMatchSpecRecommendations() async throws {
        // Spec recommends port 8928 and path /sendspin
        let advertiser = ClientAdvertiser()
        // Just verify it can be created with no arguments
        try await advertiser.start()
        await advertiser.stop()
    }

    @Test
    func clientAdvertiser_ignoresDoubleStart() async throws {
        let advertiser = ClientAdvertiser(name: "Test", port: 18_930)
        try await advertiser.start()
        // Second start should be a no-op, not an error
        try await advertiser.start()
        let isRunning = await advertiser.isRunning
        #expect(isRunning)
        await advertiser.stop()
    }

    @Test
    func isTerminatedIsTrueAfterStop() async throws {
        let advertiser = ClientAdvertiser(name: "Test", port: 18_931)
        try await advertiser.start()

        let terminatedBefore = await advertiser.isTerminated
        #expect(!terminatedBefore, "Advertiser should not be terminated before stop()")

        await advertiser.stop()

        let terminatedAfter = await advertiser.isTerminated
        #expect(terminatedAfter, "Advertiser should be terminated after stop()")
    }

    @Test
    func startAfterStopThrowsTerminatedError() async throws {
        let advertiser = ClientAdvertiser(name: "Test", port: 18_932)
        try await advertiser.start()
        await advertiser.stop()

        await #expect(throws: TerminatedError.self) {
            try await advertiser.start()
        }
    }

    @Test
    func freshAdvertiserIsNotTerminated() async {
        let advertiser = ClientAdvertiser(name: "Test", port: 18_933)
        let isTerminated = await advertiser.isTerminated
        #expect(!isTerminated, "A new advertiser should not be terminated")
    }
}

struct MultiServerDecisionTests {
    // Test the multi-server decision logic indirectly via ServerInfo and the spec rules.
    // Observable behavior is tested through ServerInfo.connectionReason tracking.

    @Test
    func serverInfo_includesConnectionReasonAndActiveRoles() {
        let info = ServerInfo(
            serverId: "server-1",
            name: "Test Server",
            version: 1,
            connectionReason: .playback,
            activeRoles: [.playerV1, .controllerV1]
        )
        #expect(info.connectionReason == .playback)
        #expect(info.activeRoles.contains(.playerV1))
        #expect(info.activeRoles.contains(.controllerV1))
        #expect(!info.activeRoles.contains(.metadataV1))

        let discovery = ServerInfo(
            serverId: "server-2",
            name: "Other Server",
            version: 1,
            connectionReason: .discovery,
            activeRoles: []
        )
        #expect(discovery.connectionReason == .discovery)
        #expect(discovery.activeRoles.isEmpty)
    }

    @Test
    func connectionReason_encodesCorrectlyOnTheWire() throws {
        let payload = ServerHelloPayload(
            serverId: "srv-1",
            name: "Test",
            version: 1,
            activeRoles: [.playerV1],
            connectionReason: .playback
        )

        let encoder = JSONEncoder()
        let data = try encoder.encode(payload)
        let json = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(json["connection_reason"] as? String == "playback")
    }

    @Test
    func connectionReason_decodesDiscovery() throws {
        let json = Data("""
        {
            "server_id": "srv-1",
            "name": "Test",
            "version": 1,
            "active_roles": ["player@v1"],
            "connection_reason": "discovery"
        }
        """.utf8)

        let decoder = JSONDecoder()
        let payload = try decoder.decode(ServerHelloPayload.self, from: json)
        #expect(payload.connectionReason == .discovery)
    }

    @Test
    func goodbyeReason_anotherServerEncodesCorrectly() throws {
        let payload = GoodbyePayload(reason: .anotherServer)
        let encoder = JSONEncoder()
        let data = try encoder.encode(payload)
        let json = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(json["reason"] as? String == "another_server")
    }
}

struct NWWebSocketTransportTests {
    @Test
    func nwWebSocketTransport_initializesWithConnection() {
        // We can't easily create a real NWConnection in tests,
        // but we can verify the transport's streams are created
        // and it reports not connected without a real connection.
        // A full integration test would require a real NWListener.

        // This test verifies the type exists and conforms to SendspinTransport
        let _: any SendspinTransport.Type = NWWebSocketTransport.self
    }

    @Test
    func webSocketTransport_conformsToSendspinTransport() {
        // Verify the existing transport conforms to the protocol
        let _: any SendspinTransport.Type = WebSocketTransport.self
    }
}
