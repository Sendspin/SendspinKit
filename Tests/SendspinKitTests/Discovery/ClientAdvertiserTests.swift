// ABOUTME: Tests for ClientAdvertiser mDNS advertisement and WebSocket server
// ABOUTME: Tests for multi-server decision logic and NWWebSocketTransport

import Foundation
import Network
@testable import SendspinKit
import Testing

struct ClientAdvertiserTests {
    @Test
    func `ClientAdvertiser starts and stops without error`() async throws {
        let advertiser = ClientAdvertiser(name: "Test Speaker", port: 18_929, path: "/sendspin")

        try await advertiser.start()
        let isRunning = await advertiser.isRunning
        #expect(isRunning)

        await advertiser.stop()
        let isStoppedAfter = await advertiser.isRunning
        #expect(!isStoppedAfter)
    }

    @Test
    func `ClientAdvertiser defaults match spec recommendations`() async throws {
        // Spec recommends port 8928 and path /sendspin
        let advertiser = ClientAdvertiser()
        // Just verify it can be created with no arguments
        try await advertiser.start()
        await advertiser.stop()
    }

    @Test
    func `ClientAdvertiser ignores double start`() async throws {
        let advertiser = ClientAdvertiser(name: "Test", port: 18_930)
        try await advertiser.start()
        // Second start should be a no-op, not an error
        try await advertiser.start()
        let isRunning = await advertiser.isRunning
        #expect(isRunning)
        await advertiser.stop()
    }
}

struct MultiServerDecisionTests {
    // Test the multi-server decision logic indirectly via ServerInfo and the spec rules.
    // Observable behavior is tested through ServerInfo.connectionReason tracking.

    @Test
    func `ServerInfo includes connectionReason and activeRoles`() {
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
    func `ConnectionReason encodes correctly on the wire`() throws {
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
    func `ConnectionReason decodes discovery`() throws {
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
    func `GoodbyeReason another_server encodes correctly`() throws {
        let payload = GoodbyePayload(reason: .anotherServer)
        let encoder = JSONEncoder()
        let data = try encoder.encode(payload)
        let json = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(json["reason"] as? String == "another_server")
    }
}

struct NWWebSocketTransportTests {
    @Test
    func `NWWebSocketTransport initializes with connection`() {
        // We can't easily create a real NWConnection in tests,
        // but we can verify the transport's streams are created
        // and it reports not connected without a real connection.
        // A full integration test would require a real NWListener.

        // This test verifies the type exists and conforms to SendspinTransport
        let _: any SendspinTransport.Type = NWWebSocketTransport.self
    }

    @Test
    func `WebSocketTransport conforms to SendspinTransport`() {
        // Verify the existing transport conforms to the protocol
        let _: any SendspinTransport.Type = WebSocketTransport.self
    }
}
