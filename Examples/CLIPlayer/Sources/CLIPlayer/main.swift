// ABOUTME: Main entry point for CLI player
// ABOUTME: Handles command-line arguments and launches the player

import Dispatch
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
    } else if arg.starts(with: "ws://") || arg.starts(with: "wss://") {
        serverURL = arg
    } else if !arg.starts(with: "--") {
        clientName = arg
    }
    argIndex += 1
}

let player = CLIPlayer()

// Shared SIGINT state: first SIGINT arms graceful shutdown, a second SIGINT
// force-exits. MainActor isolation keeps this consistent with the other
// examples (see RetryState / DashboardState) — Tasks enqueue FIFO on the
// main actor, so the second SIGINT's handler observes the flag set by the
// first without needing `nonisolated(unsafe)`.
@MainActor
final class ShutdownState {
    var latched = false
}
let shutdown = ShutdownState()

// SIGINT: graceful shutdown via DispatchSource (async-signal-safe, unlike
// calling Swift async code from a C signal handler). The handler fires on
// `.main` and hops onto MainActor to touch `ShutdownState` / run async work.
signal(SIGINT, SIG_IGN)
let sigintSource = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
sigintSource.setEventHandler {
    Task { @MainActor in
        if shutdown.latched {
            fputs("\n[SHUTDOWN] Second SIGINT — force exit.\n", stderr)
            exit(130) // 128 + SIGINT
        }
        shutdown.latched = true
        fputs("\n[SHUTDOWN] Caught SIGINT, shutting down... (Ctrl-C again to force exit)\n", stderr)
        await player.gracefulShutdown()
        exit(0)
    }
    // Fallback: force-exit if graceful shutdown hangs and the user hasn't
    // pressed Ctrl-C a second time within the window. Scheduled from the
    // dispatch handler itself (not the MainActor Task) so the fallback fires
    // even if the main actor is wedged.
    DispatchQueue.global().asyncAfter(deadline: .now() + 2) {
        fputs("[SHUTDOWN] Timed out waiting for graceful disconnect\n", stderr)
        exit(1)
    }
}
sigintSource.resume()

do {
    if listenMode {
        // Server-initiated: advertise via mDNS and wait for servers to connect
        try await player.listen(port: listenPort, clientName: clientName, useTUI: enableTUI)
    } else {
        // Client-initiated: discover or connect to provided server URL
        if serverURL == nil {
            print("Discovering Sendspin servers...")
            let servers = try await SendspinClient.discoverServers(timeout: .seconds(3))

            if servers.isEmpty {
                print("No Sendspin servers found on network")
                print("Usage: CLIPlayer [--no-tui] [ws://server:8927] [client-name]")
                print("       CLIPlayer [--no-tui] --listen [port] [client-name]")
                exit(1)
            }

            print("Found \(servers.count) server(s):")
            for (index, server) in servers.enumerated() {
                print("  [\(index + 1)] \(server.name) - \(server.url)")
            }

            let selected = servers[0]
            print("Connecting to: \(selected.name)")
            serverURL = selected.url.absoluteString
        }

        guard let url = serverURL else {
            print("No server URL available")
            exit(1)
        }
        try await player.run(serverURL: url, clientName: clientName, useTUI: enableTUI, volumeMode: volumeMode)
    }
} catch {
    print("Fatal error: \(error)")
    exit(1)
}
