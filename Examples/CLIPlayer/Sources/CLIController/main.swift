// ABOUTME: Controller-only Sendspin client example
// ABOUTME: No audio playback — just sends commands and displays server state

import Foundation
import SendspinKit

let args = CommandLine.arguments

var serverURL: String?
var clientName = "CLI Controller"

var argIndex = 1
while argIndex < args.count {
    let arg = args[argIndex]
    if arg.starts(with: "ws://") || arg.starts(with: "wss://") {
        serverURL = arg
    } else if !arg.starts(with: "--") {
        clientName = arg
    }
    argIndex += 1
}

let controller = CLIController()

signal(SIGINT) { _ in
    fputs("\n", stderr)
    Task { @MainActor in
        await controller.shutdown()
        exit(0)
    }
    DispatchQueue.global().asyncAfter(deadline: .now() + 2) { exit(1) }
}

do {
    if serverURL == nil {
        print("Discovering Sendspin servers...")
        let servers = await SendspinClient.discoverServers()

        if servers.isEmpty {
            print("No servers found.")
            print("Usage: CLIController [ws://server:8927/sendspin] [name]")
            exit(1)
        }

        let selected = servers[0]
        print("Found: \(selected.name)")
        serverURL = selected.url.absoluteString
    }

    try await controller.run(serverURL: serverURL!, clientName: clientName)
} catch {
    print("Error: \(error)")
    exit(1)
}
