// ABOUTME: Main entry point for CLI player
// ABOUTME: Handles command-line arguments and launches the player

import Foundation
import SendspinKit

// Top-level async entry point (Swift 5.5+)
let args = CommandLine.arguments

// Parse command line arguments
var serverURL: String?
var clientName = "CLI Player"
var enableTUI = true
var listenMode = false
var listenPort: UInt16 = 8928

var argIndex = 1
while argIndex < args.count {
    let arg = args[argIndex]

    if arg == "--no-tui" {
        enableTUI = false
    } else if arg == "--listen" {
        listenMode = true
        // Check if next arg is a port number
        if argIndex + 1 < args.count, let port = UInt16(args[argIndex + 1]) {
            listenPort = port
            argIndex += 1
        }
    } else if arg.starts(with: "ws://") {
        serverURL = arg
    } else if !arg.starts(with: "--") {
        clientName = arg
    }
    argIndex += 1
}

let player = CLIPlayer()

do {
    if listenMode {
        // Server-initiated: advertise via mDNS and wait for servers to connect
        try await player.listen(port: listenPort, clientName: clientName, useTUI: enableTUI)
    } else {
        // Client-initiated: discover or connect to provided server URL
        if serverURL == nil {
            print("🔍 Discovering Sendspin servers...")
            let servers = await SendspinClient.discoverServers()

            if servers.isEmpty {
                print("❌ No Sendspin servers found on network")
                print("💡 Usage: CLIPlayer [--no-tui] [ws://server:8927] [client-name]")
                print("          CLIPlayer [--no-tui] --listen [port] [client-name]")
                exit(1)
            }

            print("📡 Found \(servers.count) server(s):")
            for (index, server) in servers.enumerated() {
                print("  [\(index + 1)] \(server.name) - \(server.url)")
            }

            let selected = servers[0]
            print("✅ Connecting to: \(selected.name)")
            serverURL = selected.url.absoluteString
        }

        try await player.run(serverURL: serverURL!, clientName: clientName, useTUI: enableTUI)
    }
} catch {
    print("❌ Fatal error: \(error)")
    exit(1)
}
