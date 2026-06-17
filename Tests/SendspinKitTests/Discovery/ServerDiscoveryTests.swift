import Foundation
@testable import SendspinKit
import Testing

struct ServerDiscoveryTests {
    @Test
    func newlyCreatedInstanceIsNotTerminated() async {
        let discovery = ServerDiscovery()
        let terminated = await discovery.isTerminated
        #expect(!terminated)
    }

    @Test
    func isTerminatedBecomesTrueAfterStopDiscovery() async {
        let discovery = ServerDiscovery()
        await discovery.stopDiscovery()
        let terminated = await discovery.isTerminated
        #expect(terminated)
    }

    @Test
    func startDiscovery_throwsTerminatedErrorAfterStopDiscovery() async {
        let discovery = ServerDiscovery()
        await discovery.stopDiscovery()

        await #expect(throws: TerminatedError.self) {
            try await discovery.startDiscovery()
        }
    }

    @Test
    func stopDiscoveryIsIdempotent() async {
        let discovery = ServerDiscovery()
        await discovery.stopDiscovery()
        // Second stop should not crash or change state
        await discovery.stopDiscovery()

        let terminated = await discovery.isTerminated
        #expect(terminated)
    }

    @Test
    func multipleStopDiscoveryCallsRemainSafe() async {
        let discovery = ServerDiscovery()
        for _ in 0 ..< 5 {
            await discovery.stopDiscovery()
        }
        let terminated = await discovery.isTerminated
        #expect(terminated)
    }

    @Test
    func serversStreamExistsOnNewInstance() async {
        let discovery = ServerDiscovery()
        // The servers property should be accessible immediately after init
        _ = await discovery.servers
        await discovery.stopDiscovery()
    }

    @Test
    func serversStreamFinishesAfterStopDiscovery() async {
        let discovery = ServerDiscovery()
        let servers = await discovery.servers

        await discovery.stopDiscovery()

        // After stop, iterating the stream should complete immediately
        // (the continuation has been finished)
        var count = 0
        for await _ in servers {
            count += 1
        }
        #expect(count == 0)
    }

    // MARK: - Sendspin defaults

    @Test
    func sendspinDefaults_pinSpecDiscoveryValues() {
        #expect(SendspinDefaults.clientPort == 8_928)
        #expect(SendspinDefaults.serverPort == 8_927)
        #expect(SendspinDefaults.webSocketPath == "/sendspin")
        #expect(SendspinDefaults.clientServiceType == "_sendspin._tcp")
        #expect(SendspinDefaults.serverServiceType == "_sendspin-server._tcp")
    }

    // MARK: - Display names

    @Test
    func displayName_prefersTXTNameMetadata() {
        let displayName = ServerDiscovery.displayName(
            serviceName: "Sendspin Server",
            metadata: ["name": "Living Room", "path": "/sendspin"]
        )

        #expect(displayName == "Living Room")
    }

    @Test
    func displayName_fallsBackToServiceNameWhenTXTNameMissing() {
        let displayName = ServerDiscovery.displayName(
            serviceName: "Sendspin Server",
            metadata: ["path": "/sendspin"]
        )

        #expect(displayName == "Sendspin Server")
    }

    @Test
    func displayName_fallsBackToServiceNameWhenTXTNameEmpty() {
        let displayName = ServerDiscovery.displayName(
            serviceName: "Sendspin Server",
            metadata: ["name": ""]
        )

        #expect(displayName == "Sendspin Server")
    }

    @Test
    func discoveredServerIDUsesServiceNameWhenDisplayNameDiffers() throws {
        let url = try #require(URL(string: "ws://example.local:8080/ws"))
        let server = DiscoveredServer(
            serviceName: "Sendspin Server",
            name: "Living Room",
            url: url,
            hostname: "example.local",
            port: 8_080,
            metadata: ["name": "Living Room"]
        )

        #expect(server.id == "Sendspin Server")
        #expect(server.serviceName == "Sendspin Server")
        #expect(server.name == "Living Room")
        #expect(server.metadata["name"] == "Living Room")
    }

    // MARK: - Interface scope stripping

    @Test
    func stripInterfaceScope_removesPercentSuffix() {
        // IPv4 with interface scope (common on macOS)
        #expect(ServerDiscovery.stripInterfaceScope("192.168.1.181%en0") == "192.168.1.181")
    }

    @Test
    func stripInterfaceScope_preservesBareAddress() {
        // No scope — should pass through unchanged
        #expect(ServerDiscovery.stripInterfaceScope("192.168.1.181") == "192.168.1.181")
    }

    @Test
    func stripInterfaceScope_handlesIPv6WithScope() {
        #expect(ServerDiscovery.stripInterfaceScope("fe80::1%en0") == "fe80::1")
    }

    @Test
    func stripInterfaceScope_handlesEmptyString() {
        #expect(ServerDiscovery.stripInterfaceScope("") == "")
    }

    // MARK: - Resolved WebSocket path (TXT record)

    @Test
    func resolvedWebSocketPath_acceptsAbsolutePaths() {
        #expect(ServerDiscovery.resolvedWebSocketPath("/sendspin") == "/sendspin")
        #expect(ServerDiscovery.resolvedWebSocketPath("/custom/ws") == "/custom/ws")
    }

    @Test
    func resolvedWebSocketPath_fallsBackForNilOrEmpty() {
        #expect(ServerDiscovery.resolvedWebSocketPath(nil) == SendspinDefaults.webSocketPath)
        #expect(ServerDiscovery.resolvedWebSocketPath("") == SendspinDefaults.webSocketPath)
    }

    @Test
    func resolvedWebSocketPath_rejectsNonAbsolutePaths() {
        // Missing leading slash: malformed when concatenated onto host:port.
        #expect(ServerDiscovery.resolvedWebSocketPath("sendspin") == SendspinDefaults.webSocketPath)
        // Authority-injection attempt: "@host/" would otherwise redirect the dial
        // to a different host. Rejecting non-absolute paths closes that vector.
        #expect(ServerDiscovery.resolvedWebSocketPath("@evil.host/") == SendspinDefaults.webSocketPath)
    }

    // MARK: - TerminatedError

    @Test
    func terminatedError_hasMeaningfulDescription() {
        let error = TerminatedError()
        #expect(error.description.contains("permanently stopped"))
        #expect(error.errorDescription?.contains("permanently stopped") == true)
    }

    @Test
    func terminatedError_conformsToSendspinError() {
        let error: any Error = TerminatedError()
        #expect(error is any SendspinError)
    }
}
