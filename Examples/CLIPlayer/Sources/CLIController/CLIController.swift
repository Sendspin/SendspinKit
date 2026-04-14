// ABOUTME: Controller-only Sendspin client — no audio, just commands
// ABOUTME: Demonstrates using SendspinKit with only the controller role

import Foundation
import SendspinKit

/// A controller-only Sendspin client.
///
/// Connects with just `controller` (and optionally `metadata`) roles — no player,
/// no audio pipeline, no artwork. Useful for wall-mounted tablets, remote control
/// apps, or any device that controls playback without outputting audio.
final class CLIController {
    private var client: SendspinClient?

    @MainActor
    func run(serverURL: String, clientName: String) async throws {
        guard let url = URL(string: serverURL) else {
            print("Invalid URL: \(serverURL)")
            return
        }

        let client = SendspinClient(
            clientId: UUID().uuidString,
            name: clientName,
            roles: [.controllerV1, .metadataV1]
            // No playerConfig, no artworkConfig — controller-only
        )
        self.client = client

        // Monitor events
        Task {
            await monitorEvents(client: client)
        }

        try await client.connect(to: url)

        print("Connected to \(serverURL)")
        printHelp()

        // Fire-and-forget command loop
        Task.detached { [client] in
            await CLIController.commandLoop(client: client)
        }

        // Stay alive until disconnected
        for await event in client.events {
            if case .disconnected = event { break }
        }
    }

    @MainActor
    func shutdown() async {
        await client?.disconnect(reason: .shutdown)
    }

    // MARK: - Events

    @MainActor
    private func monitorEvents(client: SendspinClient) async {
        for await event in client.events {
            switch event {
            case let .serverConnected(info):
                print("[server] \(info.name) (v\(info.version), reason: \(info.connectionReason))")

            case let .controllerStateUpdated(state):
                let cmds = state.supportedCommands.map(\.rawValue).joined(separator: ", ")
                print("[controller] commands: \(cmds)")
                print("[controller] group volume: \(state.volume), muted: \(state.muted)")

            case let .metadataReceived(metadata):
                let title = metadata.title ?? "—"
                let artist = metadata.artist ?? "—"
                let album = metadata.album ?? "—"
                print("[now playing] \(artist) - \(title) (\(album))")

                if let progress = metadata.progress {
                    let pos = Self.formatMs(progress.trackProgressMs)
                    let dur = progress.trackDurationMs > 0 ? Self.formatMs(progress.trackDurationMs) : "live"
                    let speed = progress.playbackSpeedX1000 == 0 ? "paused" : "\(Double(progress.playbackSpeedX1000) / 1000.0)x"
                    print("[progress] \(pos) / \(dur) [\(speed)]")
                }

                if let mode = metadata.repeatMode {
                    print("[repeat] \(mode.rawValue)")
                }
                if let shuffle = metadata.shuffle {
                    print("[shuffle] \(shuffle ? "on" : "off")")
                }

            case let .groupUpdated(info):
                let state = info.playbackState?.rawValue ?? "unknown"
                print("[group] \(info.groupName.isEmpty ? info.groupId : info.groupName): \(state)")

            case .streamStarted, .streamFormatChanged, .streamEnded:
                break // Not relevant for controller-only

            case let .disconnected(reason):
                print("[disconnected] \(reason)")

            default:
                break
            }
        }
    }

    // MARK: - Command loop

    private nonisolated static func commandLoop(client: SendspinClient) async {
        while let line = readLine() {
            let parts = line.split(separator: " ")
            guard let cmd = parts.first else { continue }

            switch cmd.lowercased() {
            case "p", "play":
                await client.play()
            case "pause":
                await client.pause()
            case "s", "stop":
                await client.stopPlayback()
            case "n", "next":
                await client.next()
            case "b", "prev", "previous":
                await client.previous()

            case "v", "vol", "volume":
                guard parts.count > 1, let vol = Int(parts[1]) else {
                    print("Usage: vol <0-100>")
                    continue
                }
                await client.setGroupVolume(vol)

            case "m", "mute":
                await client.setGroupMute(true)
            case "u", "unmute":
                await client.setGroupMute(false)

            case "repeat":
                guard parts.count > 1 else {
                    print("Usage: repeat <off|one|all>")
                    continue
                }
                switch parts[1].lowercased() {
                case "off": await client.repeatOff()
                case "one": await client.repeatOne()
                case "all": await client.repeatAll()
                default: print("Usage: repeat <off|one|all>")
                }

            case "shuffle":
                await client.shuffle()
            case "unshuffle":
                await client.unshuffle()

            case "switch":
                await client.switchGroup()

            case "q", "quit", "exit":
                await client.disconnect()
                return

            case "?", "h", "help":
                printHelp()

            default:
                print("Unknown command. Type 'help' for commands.")
            }
        }
    }

    // MARK: - Helpers

    private static func formatMs(_ ms: Int) -> String {
        let totalSeconds = ms / 1000
        let minutes = totalSeconds / 60
        let seconds = totalSeconds % 60
        return String(format: "%d:%02d", minutes, seconds)
    }
}

private func printHelp() {
    print("""
    Commands:
      p, play          Resume playback
      pause            Pause playback
      s, stop          Stop playback
      n, next          Next track
      b, prev          Previous track
      v, vol <0-100>   Set group volume
      m, mute          Mute group
      u, unmute        Unmute group
      repeat <mode>    Set repeat: off, one, all
      shuffle          Enable shuffle
      unshuffle        Disable shuffle
      switch           Switch to next group
      q, quit          Disconnect and exit
    """)
}
