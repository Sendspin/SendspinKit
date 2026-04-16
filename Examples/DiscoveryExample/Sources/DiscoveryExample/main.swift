// ABOUTME: One-shot mDNS discovery example
// ABOUTME: Scans the local network for Sendspin servers and prints what it finds

import ArgumentParser
import Foundation
import SendspinKit

// AsyncParsableCommand lets ArgumentParser manage the async entry point for us.
// The run() method is called automatically with the parsed arguments in place.
@main
struct DiscoveryExample: AsyncParsableCommand {

    static let configuration = CommandConfiguration(
        commandName: "DiscoveryExample",
        abstract: "Scan the local network for Sendspin servers via mDNS."
    )

    // How long to listen for mDNS announcements before giving up.
    // Longer timeouts find servers that are slow to respond.
    @Option(name: .long, help: "Discovery timeout in seconds.")
    var timeout: Double = 5.0

    // Verbose mode dumps each server's TXT record metadata (version, group, etc.)
    @Flag(name: .long, help: "Show TXT record metadata for each server.")
    var verbose: Bool = false

    func run() async throws {
        print("Scanning for Sendspin servers (\(timeout)s timeout)...")

        // discoverServers(timeout:) is a one-shot convenience: it starts mDNS
        // browsing, waits for the given duration, then returns whatever was found.
        // For a continuously-updating live list use the overload that returns
        // ServerDiscovery with an AsyncStream<[DiscoveredServer]>.
        let servers = try await SendspinClient.discoverServers(
            timeout: .seconds(Int(timeout))
        )

        guard !servers.isEmpty else {
            print("No Sendspin servers found on the network.")
            // Exit with a non-zero code so callers (scripts, CI) can detect this.
            throw ExitCode.failure
        }

        print("Found \(servers.count) server\(servers.count == 1 ? "" : "s"):\n")

        for server in servers {
            // Every DiscoveredServer has a name (Bonjour service name), a ready-to-use
            // WebSocket URL, and the resolved hostname + port for display.
            print("  \(server.name)")
            print("  URL:  \(server.url)")
            print("  Host: \(server.hostname):\(server.port)")

            if verbose, !server.metadata.isEmpty {
                // Metadata comes from the server's DNS-SD TXT records — things like
                // protocol version, group name, or application-defined fields.
                print("  Metadata:")
                // Sort for deterministic output.
                for (key, value) in server.metadata.sorted(by: { $0.key < $1.key }) {
                    print("    \(key): \(value)")
                }
            }

            print("")
        }
    }
}
