// ABOUTME: Interactive terminal controller for Sendspin playback
// ABOUTME: Reads single keypresses in raw mode — no Enter required

import ArgumentParser
import Darwin
import Foundation
import SendspinKit

// MARK: - Terminal raw mode helpers

/// Read the current terminal attributes so we can restore them on exit.
/// Capture this BEFORE the first `enableRawMode()` call.
private func captureTerminalMode() -> termios {
    var mode = termios()
    tcgetattr(STDIN_FILENO, &mode)
    return mode
}

/// Switch stdin to raw mode: single-byte reads, no echo, no line buffering.
/// Pairs with `restoreTerminalMode(_:)` — always restore before exit or the
/// user's shell is left in an unusable state.
private func enableRawMode() {
    var raw = termios()
    tcgetattr(STDIN_FILENO, &raw)
    raw.c_lflag &= ~UInt(ICANON | ECHO)
    withUnsafeMutableBytes(of: &raw.c_cc) { ccBytes in
        ccBytes[Int(VMIN)] = 1
        ccBytes[Int(VTIME)] = 0
    }
    tcsetattr(STDIN_FILENO, TCSAFLUSH, &raw)
}

/// Restore the terminal attributes captured by `captureTerminalMode()`.
private func restoreTerminalMode(_ mode: termios) {
    var mutableMode = mode
    tcsetattr(STDIN_FILENO, TCSAFLUSH, &mutableMode)
}

// MARK: - Server URL resolution

private func resolveServerURL(server: String?, discover: Bool, timeout: Double) async throws -> URL {
    if let server {
        guard let url = URL(string: server) else {
            throw ValidationError("Invalid server URL: \(server)")
        }
        return url
    }
    if discover {
        // Preserve fractional seconds — `.seconds(Int(timeout))` would truncate
        // `--timeout 2.5` to 2.0. `.milliseconds` is whole-number friendly.
        let servers = try await SendspinClient.discoverServers(
            timeout: .milliseconds(Int(timeout * 1000))
        )
        guard let first = servers.first else {
            throw ValidationError("No servers found via mDNS discovery")
        }
        print("Discovered: \(first.name) at \(first.url)")
        return first.url
    }
    throw ValidationError("Provide --server <url> or --discover")
}

// MARK: - Shared playback state

/// Mirrors the bits of server state that the key loop needs to make decisions
/// (what to toggle, what direction to cycle). Updated from the event task,
/// read from the key loop — both on MainActor.
@MainActor
private final class PlaybackUIState {
    var isPlaying = false
    var currentVolume = 100
    var isMuted = false
    var repeatMode: RepeatMode = .off
    var isShuffled = false
}

// MARK: - Command

@main
struct ControllerClient: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Interactive terminal controller for Sendspin playback."
    )

    @Option(help: "WebSocket URL of the Sendspin server (e.g. ws://192.168.1.10:8927/sendspin)")
    var server: String?

    @Flag(help: "Auto-discover a server via mDNS")
    var discover: Bool = false

    @Option(help: "Discovery timeout in seconds")
    var timeout: Double = 5.0

    @MainActor
    func run() async throws {
        let url = try await resolveServerURL(server: server, discover: discover, timeout: timeout)

        let client = try SendspinClient(
            clientId: "controller-example-\(UUID().uuidString.prefix(8))",
            name: "Controller Client",
            roles: [.controllerV1, .metadataV1]
        )

        try await client.connect(to: url)
        print("Connected to \(url)")
        printHelp()

        let state = PlaybackUIState()
        let eventTask = Task { @MainActor in
            await Self.monitorEvents(client: client, state: state)
        }

        // Enable raw mode — single keypress, no Enter required.
        // Capture the original attributes FIRST, then switch to raw. The defer
        // ensures the terminal is restored even if we exit via an unhandled
        // error or unexpected throw — a broken terminal is miserable.
        let originalTermios = captureTerminalMode()
        enableRawMode()
        defer { restoreTerminalMode(originalTermios) }

        await Self.runKeyLoop(client: client, state: state, originalTermios: originalTermios)

        // defer handles restoreTerminalMode — no manual call needed here.
        print("\nDisconnecting...")
        eventTask.cancel()
        await client.disconnect(reason: .shutdown)
    }

    /// Monitor server events and update shared playback state.
    /// Exits the event loop when the connection drops.
    @MainActor
    private static func monitorEvents(client: SendspinClient, state: PlaybackUIState) async {
        for await event in client.events {
            switch event {
            case let .serverConnected(info):
                let roles = info.activeRoles.map(\.identifier).joined(separator: ", ")
                print("\n[connected] \(info.name) — active roles: \(roles)")

            case let .controllerStateUpdated(ctrl):
                state.currentVolume = ctrl.volume
                state.isMuted = ctrl.muted
                let supported = ctrl.supportedCommands.map(\.rawValue).sorted().joined(separator: ", ")
                print("\n[controller] vol=\(ctrl.volume) muted=\(ctrl.muted) commands: \(supported)")

            case let .metadataReceived(metadata):
                let artist = metadata.artist ?? "Unknown"
                let title = metadata.title ?? "Unknown"
                if let progress = metadata.progress {
                    state.isPlaying = progress.playbackSpeedX1000 != 0
                }
                if let mode = metadata.repeatMode {
                    state.repeatMode = mode
                }
                if let shuffle = metadata.shuffle {
                    state.isShuffled = shuffle
                }
                print("\n[now playing] \(artist) - \(title)")

            case let .groupUpdated(info):
                if info.playbackState == .playing {
                    state.isPlaying = true
                } else if info.playbackState == .stopped {
                    state.isPlaying = false
                }

            case let .disconnected(reason):
                print("\n[disconnected] \(reason)")
                return

            default:
                break
            }
        }
    }

    /// Read keypresses in raw mode and dispatch playback commands.
    /// Returns when the user presses `q`.
    @MainActor
    private static func runKeyLoop(
        client: SendspinClient,
        state: PlaybackUIState,
        originalTermios: termios
    ) async {
        // Key-reading loop on main actor (read() is blocking but ArgumentParser's
        // AsyncParsableCommand runs on a dedicated thread so we won't starve the
        // main run loop; we use a detached task to do the blocking read off-actor).
        //
        // Tradeoff: one detached Task per keypress is simple and correct for an
        // interactive controller (humans type ~5 keys/sec max, so Task allocation
        // overhead is negligible). For higher-throughput inputs (serial port, MIDI,
        // game controller) a single long-lived reader thread feeding an AsyncStream
        // would amortise that cost — but the complexity isn't worth it here.
        var keepRunning = true
        while keepRunning {
            let key = await Task.detached(priority: .userInitiated) {
                var byte: UInt8 = 0
                let bytesRead = read(STDIN_FILENO, &byte, 1)
                return bytesRead > 0 ? byte : 0
            }.value

            keepRunning = await handleKey(key, client: client, state: state, originalTermios: originalTermios)
        }
    }

    /// Dispatch a single keypress. Returns `false` when the user has requested exit.
    @MainActor
    private static func handleKey(
        _ key: UInt8,
        client: SendspinClient,
        state: PlaybackUIState,
        originalTermios: termios
    ) async -> Bool {
        switch key {
        case UInt8(ascii: " "):
            if state.isPlaying {
                try? await client.pause()
                state.isPlaying = false
                print("\r[pause]       ", terminator: "")
            } else {
                try? await client.play()
                state.isPlaying = true
                print("\r[play]        ", terminator: "")
            }

        case UInt8(ascii: "n"):
            try? await client.next()
            print("\r[next]        ", terminator: "")

        case UInt8(ascii: "p"):
            try? await client.previous()
            print("\r[previous]    ", terminator: "")

        case UInt8(ascii: "+"), UInt8(ascii: "]"):
            state.currentVolume = min(100, state.currentVolume + 5)
            try? await client.setGroupVolume(state.currentVolume)
            print("\r[volume] \(state.currentVolume)   ", terminator: "")

        case UInt8(ascii: "-"), UInt8(ascii: "["):
            state.currentVolume = max(0, state.currentVolume - 5)
            try? await client.setGroupVolume(state.currentVolume)
            print("\r[volume] \(state.currentVolume)   ", terminator: "")

        case UInt8(ascii: "m"):
            state.isMuted.toggle()
            try? await client.setGroupMute(state.isMuted)
            print("\r[mute] \(state.isMuted ? "on" : "off")   ", terminator: "")

        case UInt8(ascii: "s"):
            state.isShuffled.toggle()
            try? await client.setShuffle(state.isShuffled)
            print("\r[shuffle] \(state.isShuffled ? "on" : "off")   ", terminator: "")

        case UInt8(ascii: "r"):
            // Cycle repeat: off -> one -> all -> off
            switch state.repeatMode {
            case .off:
                state.repeatMode = .one
            case .one:
                state.repeatMode = .all
            case .all:
                state.repeatMode = .off
            }
            try? await client.setRepeatMode(state.repeatMode)
            print("\r[repeat] \(state.repeatMode.rawValue)   ", terminator: "")

        case UInt8(ascii: "q"):
            return false

        case UInt8(ascii: "?"), UInt8(ascii: "h"):
            // Restore normal mode briefly so help text displays cleanly,
            // then switch back to raw. We keep `originalTermios` for the defer
            // in the caller — no need to re-capture.
            restoreTerminalMode(originalTermios)
            print("")
            printHelp()
            enableRawMode()

        default:
            break
        }
        return true
    }
}

private func printHelp() {
    print("""
    Keys:
      SPACE      Play / Pause toggle
      n          Next track
      p          Previous track
      + or ]     Volume up 5
      - or [     Volume down 5
      m          Toggle mute
      s          Toggle shuffle
      r          Cycle repeat: off -> one -> all
      q          Quit
      h or ?     Show this help
    """)
}
