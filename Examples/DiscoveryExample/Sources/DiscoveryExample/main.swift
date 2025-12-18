// ABOUTME: Demonstrates mDNS/Bonjour server discovery for SendspinKit
// ABOUTME: Shows how to find Sendspin servers on the local network

import Foundation
import SendspinKit
import ArgumentParser

@main
struct DiscoveryExample: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Discover Sendspin servers on the local network using mDNS/Bonjour",
        discussion: """
            This example demonstrates how to use SendspinKit's server discovery feature.
            It will scan the local network for Sendspin servers advertising via Bonjour
            and display their connection details.

            The discovery process uses mDNS to find servers advertising the _sendspin._tcp service.
            """
    )

    @Option(name: .shortAndLong, help: "Discovery timeout in seconds")
    var timeout: Int = 5

    @Flag(name: .shortAndLong, help: "Show detailed information about each server")
    var verbose: Bool = false

    mutating func run() async throws {
        // Validate timeout is reasonable
        guard timeout > 0 && timeout <= 60 else {
            throw ValidationError("Timeout must be between 1 and 60 seconds")
        }

        print("🔍 Discovering Sendspin servers...")
        print("⏱️  Timeout: \(timeout) second\(timeout == 1 ? "" : "s")")
        print("")

        // Convert timeout to Duration
        // We use Duration.seconds() because it's type-safe and more modern than TimeInterval
        let timeoutDuration = Duration.seconds(timeout)

        // Call the discovery API
        // This performs an async mDNS scan for _sendspin._tcp services on the local network
        let servers = await SendspinClient.discoverServers(timeout: timeoutDuration)

        // Check if any servers were found
        if servers.isEmpty {
            print("❌ No Sendspin servers found on the local network")
            print("")
            print("💡 Tips:")
            print("   • Make sure a Sendspin server is running")
            print("   • Check that the server is on the same network")
            print("   • Verify firewall settings allow mDNS traffic")
            print("   • Try increasing the timeout with --timeout")

            // Exit with code 1 to indicate no servers found
            // This allows scripts to check the discovery result
            throw ExitCode.failure
        }

        // Display the results
        print("✅ Found \(servers.count) server\(servers.count == 1 ? "" : "s"):")
        print("")

        for (index, server) in servers.enumerated() {
            // Display basic information for each server
            print("[\(index + 1)] \(server.name)")
            print("    URL:      \(server.url)")
            print("    Host:     \(server.hostname):\(server.port)")

            // In verbose mode, show additional metadata from TXT records
            // TXT records may contain version info, capabilities, or other server metadata
            if verbose && !server.metadata.isEmpty {
                print("    Metadata:")
                for (key, value) in server.metadata.sorted(by: { $0.key < $1.key }) {
                    print("      \(key): \(value)")
                }
            }

            print("")
        }

        // Exit successfully
        // Exit code 0 indicates at least one server was found
        print("✨ Discovery complete!")
    }
}
