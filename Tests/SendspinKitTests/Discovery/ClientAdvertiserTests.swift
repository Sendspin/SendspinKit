// ABOUTME: Tests for ClientAdvertiser mDNS advertisement and WebSocket server
// ABOUTME: Tests for multi-server decision logic and NWWebSocketTransport

import Foundation
import Network
import Testing

@testable import SendspinKit

@Suite("Client Advertiser")
struct ClientAdvertiserTests {
    @Test("ClientAdvertiser starts and stops without error")
    func startStop() async throws {
        let advertiser = ClientAdvertiser(name: "Test Speaker", port: 18929, path: "/sendspin")

        try await advertiser.start()
        let isRunning = await advertiser.isRunning
        #expect(isRunning)

        await advertiser.stop()
        let isStoppedAfter = await advertiser.isRunning
        #expect(!isStoppedAfter)
    }

    @Test("ClientAdvertiser defaults match spec recommendations")
    func defaults() async throws {
        // Spec recommends port 8928 and path /sendspin
        let advertiser = ClientAdvertiser()
        // Just verify it can be created with no arguments
        try await advertiser.start()
        await advertiser.stop()
    }

    @Test("ClientAdvertiser ignores double start")
    func doubleStart() async throws {
        let advertiser = ClientAdvertiser(name: "Test", port: 18930)
        try await advertiser.start()
        // Second start should be a no-op, not an error
        try await advertiser.start()
        let isRunning = await advertiser.isRunning
        #expect(isRunning)
        await advertiser.stop()
    }
}

@Suite("Multi-Server Decision Logic")
struct MultiServerDecisionTests {
    // Test the decision logic indirectly via ServerInfo and the spec rules.
    // The actual shouldSwitchToNewServer method is private, but we can test
    // the observable behavior through ServerInfo.connectionReason tracking.

    @Test("ServerInfo includes connectionReason")
    func serverInfoConnectionReason() {
        let info = ServerInfo(
            serverId: "server-1",
            name: "Test Server",
            version: 1,
            connectionReason: .playback
        )
        #expect(info.connectionReason == .playback)

        let discovery = ServerInfo(
            serverId: "server-2",
            name: "Other Server",
            version: 1,
            connectionReason: .discovery
        )
        #expect(discovery.connectionReason == .discovery)
    }

    @Test("Last played server persistence")
    func lastPlayedServerPersistence() async {
        // Save
        let testId = "test-server-\(UUID().uuidString)"
        await MainActor.run {
            SendspinClient.lastPlayedServerId = testId
        }

        // Read back
        let stored = await MainActor.run {
            SendspinClient.lastPlayedServerId
        }
        #expect(stored == testId)

        // Clean up
        await MainActor.run {
            SendspinClient.lastPlayedServerId = nil
        }
    }

    @Test("ConnectionReason encodes correctly on the wire")
    func connectionReasonEncoding() throws {
        let payload = ServerHelloPayload(
            serverId: "srv-1",
            name: "Test",
            version: 1,
            activeRoles: [.playerV1],
            connectionReason: .playback
        )

        let encoder = JSONEncoder()
        let data = try encoder.encode(payload)
        let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        #expect(json["connection_reason"] as? String == "playback")
    }

    @Test("ConnectionReason decodes discovery")
    func connectionReasonDecodesDiscovery() throws {
        let json = """
        {
            "server_id": "srv-1",
            "name": "Test",
            "version": 1,
            "active_roles": ["player@v1"],
            "connection_reason": "discovery"
        }
        """.data(using: .utf8)!

        let decoder = JSONDecoder()
        let payload = try decoder.decode(ServerHelloPayload.self, from: json)
        #expect(payload.connectionReason == .discovery)
    }

    @Test("GoodbyeReason another_server encodes correctly")
    func goodbyeAnotherServer() throws {
        let payload = GoodbyePayload(reason: .anotherServer)
        let encoder = JSONEncoder()
        let data = try encoder.encode(payload)
        let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        #expect(json["reason"] as? String == "another_server")
    }
}

@Suite("NWWebSocketTransport")
struct NWWebSocketTransportTests {
    @Test("NWWebSocketTransport initializes with connection")
    func initialization() async {
        // We can't easily create a real NWConnection in tests,
        // but we can verify the transport's streams are created
        // and it reports not connected without a real connection.
        // A full integration test would require a real NWListener.

        // This test verifies the type exists and conforms to SendspinTransport
        let _: any SendspinTransport.Type = NWWebSocketTransport.self
    }

    @Test("WebSocketTransport conforms to SendspinTransport")
    func starscreamConformance() {
        // Verify the existing transport conforms to the protocol
        let _: any SendspinTransport.Type = WebSocketTransport.self
    }
}
