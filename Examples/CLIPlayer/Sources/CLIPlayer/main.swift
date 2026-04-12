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
var volumeMode: VolumeMode = .software

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
    } else if arg == "--volume-mode" {
        if argIndex + 1 < args.count {
            argIndex += 1
            switch args[argIndex] {
            case "software": volumeMode = .software
            case "hardware": volumeMode = .hardware
            case "none": volumeMode = .none
            default:
                print("Unknown volume mode '\(args[argIndex])'. Use: software, hardware, none")
                exit(1)
            }
        }
    } else if arg.starts(with: "ws://") {
        serverURL = arg
    } else if !arg.starts(with: "--") {
        clientName = arg
    }
    argIndex += 1
}

let player = CLIPlayer()

// Catch SIGINT (Ctrl-C) for graceful shutdown — sends client/goodbye
// so the server knows we're shutting down and won't keep retrying.
signal(SIGINT) { _ in
    fputs("\n[SHUTDOWN] Caught SIGINT, shutting down...\n", stderr)
    // Schedule async disconnect on the main actor, then exit
    Task { @MainActor in
        await player.gracefulShutdown()
        exit(0)
    }
    // Give the async work a moment, then force-exit as a fallback
    DispatchQueue.global().asyncAfter(deadline: .now() + 2) {
        fputs("[SHUTDOWN] Timed out waiting for graceful disconnect\n", stderr)
        exit(1)
    }
}

do {
    if listenMode {
        // Server-initiated: advertise via mDNS and wait for servers to connect
        try await player.listen(port: listenPort, clientName: clientName, useTUI: enableTUI)
    } else {
        // Client-initiated: discover or connect to provided server URL
        if serverURL == nil {
            print("🔍 Discovering Sendspin servers...")
            let servers = await SendspinClient.discoverServers(timeout: .seconds(3))

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

        try await player.run(serverURL: serverURL!, clientName: clientName, useTUI: enableTUI, volumeMode: volumeMode)
    }
} catch {
    print("❌ Fatal error: \(error)")
    exit(1)
}
