// ABOUTME: Interactive terminal controller for Sendspin playback
// ABOUTME: Reads single keypresses in raw mode — no Enter required

import ArgumentParser
import Darwin
import Foundation
import SendspinKit

// MARK: - Terminal raw mode helpers

/// Read the current terminal attributes so we can restore them on exit.
/// Capture this BEFORE the first `enableRawMode()` call.
///
/// Returns `nil` if stdin is not a TTY — e.g. when input is redirected from a
/// file or pipe. Callers must handle this: we can't usefully interact without
/// a terminal, and writing zero-initialized `termios` back via `tcsetattr`
/// would leave the user's shell mis-configured.
private func captureTerminalMode() -> termios? {
    var mode = termios()
    guard tcgetattr(STDIN_FILENO, &mode) == 0 else { return nil }
    return mode
}

/// Switch stdin to raw mode: single-byte reads, no echo, no line buffering.
/// Pairs with `restoreTerminalMode(_:)` — always restore before exit or the
/// user's shell is left in an unusable state.
///
/// Returns `false` if the stdin is not a TTY. In that case nothing has been
/// mutated and there is nothing to restore.
@discardableResult
private func enableRawMode() -> Bool {
    var raw = termios()
    guard tcgetattr(STDIN_FILENO, &raw) == 0 else { return false }
    raw.c_lflag &= ~UInt(ICANON | ECHO)
    withUnsafeMutableBytes(of: &raw.c_cc) { ccBytes in
        ccBytes[Int(VMIN)] = 1
        ccBytes[Int(VTIME)] = 0
    }
    return tcsetattr(STDIN_FILENO, TCSAFLUSH, &raw) == 0
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
        // TTY guard FIRST — capturing terminal attributes fails if stdin is
        // redirected from a file or pipe. Without a real terminal, raw-mode
        // single-keypress reads don't make sense, and writing zero-initialized
        // `termios` back on exit would leave the parent shell broken.
        guard let originalTermios = captureTerminalMode() else {
            fputs("stdin is not a TTY — ControllerClient requires an interactive terminal.\n", stderr)
            throw ExitCode.failure
        }

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

        // Enable raw mode — single keypress, no Enter required. The defer
        // ensures the terminal is restored even if we exit via an unhandled
        // error or unexpected throw — a broken terminal is miserable.
        enableRawMode()
        defer { restoreTerminalMode(originalTermios) }

        // Closure for the `h`/`?` path: briefly return to cooked mode so help
        // prints with normal line endings, then switch back. Captures
        // `originalTermios` so `handleKey` doesn't have to take it as an arg.
        let showHelpInCookedMode: @MainActor () -> Void = {
            restoreTerminalMode(originalTermios)
            print("")
            printHelp()
            enableRawMode()
        }

        await Self.runKeyLoop(client: client, state: state, showHelp: showHelpInCookedMode)

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
        showHelp: @MainActor () -> Void
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

            keepRunning = await handleKey(key, client: client, state: state, showHelp: showHelp)
        }
    }

    /// Dispatch a single keypress. Returns `false` when the user has requested exit.
    ///
    /// Local state (`state.isPlaying`, `state.currentVolume`, …) is committed
    /// only *after* the send succeeds. On send failure, we leave local state
    /// unchanged and print a `[… failed]` line — the next server event will
    /// reconcile any drift caused by a server-side rejection.
    @MainActor
    private static func handleKey(
        _ key: UInt8,
        client: SendspinClient,
        state: PlaybackUIState,
        showHelp: @MainActor () -> Void
    ) async -> Bool {
        switch key {
        case UInt8(ascii: " "):
            let targetPlaying = !state.isPlaying
            do {
                if targetPlaying {
                    try await client.play()
                    print("\r[play]        ", terminator: "")
                } else {
                    try await client.pause()
                    print("\r[pause]       ", terminator: "")
                }
                state.isPlaying = targetPlaying
            } catch {
                print("\r[play/pause failed: \(error.localizedDescription)]  ", terminator: "")
            }

        case UInt8(ascii: "n"):
            do {
                try await client.next()
                print("\r[next]        ", terminator: "")
            } catch {
                print("\r[next failed: \(error.localizedDescription)]  ", terminator: "")
            }

        case UInt8(ascii: "p"):
            do {
                try await client.previous()
                print("\r[previous]    ", terminator: "")
            } catch {
                print("\r[previous failed: \(error.localizedDescription)]  ", terminator: "")
            }

        case UInt8(ascii: "+"), UInt8(ascii: "]"):
            let newVolume = min(100, state.currentVolume + 5)
            do {
                try await client.setGroupVolume(newVolume)
                state.currentVolume = newVolume
                print("\r[volume] \(newVolume)   ", terminator: "")
            } catch {
                print("\r[volume up failed: \(error.localizedDescription)]  ", terminator: "")
            }

        case UInt8(ascii: "-"), UInt8(ascii: "["):
            let newVolume = max(0, state.currentVolume - 5)
            do {
                try await client.setGroupVolume(newVolume)
                state.currentVolume = newVolume
                print("\r[volume] \(newVolume)   ", terminator: "")
            } catch {
                print("\r[volume down failed: \(error.localizedDescription)]  ", terminator: "")
            }

        case UInt8(ascii: "m"):
            let newMuted = !state.isMuted
            do {
                try await client.setGroupMute(newMuted)
                state.isMuted = newMuted
                print("\r[mute] \(newMuted ? "on" : "off")   ", terminator: "")
            } catch {
                print("\r[mute failed: \(error.localizedDescription)]  ", terminator: "")
            }

        case UInt8(ascii: "s"):
            let newShuffle = !state.isShuffled
            do {
                try await client.setShuffle(newShuffle)
                state.isShuffled = newShuffle
                print("\r[shuffle] \(newShuffle ? "on" : "off")   ", terminator: "")
            } catch {
                print("\r[shuffle failed: \(error.localizedDescription)]  ", terminator: "")
            }

        case UInt8(ascii: "r"):
            // Cycle repeat: off -> one -> all -> off
            let nextMode: RepeatMode = switch state.repeatMode {
            case .off: .one
            case .one: .all
            case .all: .off
            }
            do {
                try await client.setRepeatMode(nextMode)
                state.repeatMode = nextMode
                print("\r[repeat] \(nextMode.rawValue)   ", terminator: "")
            } catch {
                print("\r[repeat failed: \(error.localizedDescription)]  ", terminator: "")
            }

        case UInt8(ascii: "q"):
            return false

        case UInt8(ascii: "?"), UInt8(ascii: "h"):
            showHelp()

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
