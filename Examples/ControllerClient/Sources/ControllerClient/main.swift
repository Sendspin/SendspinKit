// ABOUTME: Demonstrates controller-only client for SendspinKit
// ABOUTME: Connects as controller role to send remote control commands without playing audio

import Foundation
import SendspinKit
import ArgumentParser

@main
struct ControllerClient: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Control playback without local audio output (silent player pattern)",
        discussion: """
            This example demonstrates how to control playback without playing audio locally.
            It uses the player role with minimal configuration but doesn't consume audio
            chunks, creating a "silent player" that can send control commands.

            This is useful for:
            • Remote control applications
            • Headless automation systems
            • Multi-room audio control panels
            • Testing player control functionality

            The client provides an interactive command interface to control its own
            playback state (volume, mute), which the server coordinates with the group.

            Available commands:
            • + / -     Increase/decrease volume by 10%
            • m         Mute audio
            • u         Unmute audio
            • q         Quit

            Note: This demonstrates the "silent player" pattern - a player that
            participates in the session for control purposes but doesn't output audio.
            """
    )

    @Option(name: .shortAndLong, help: "Server URL (e.g., ws://localhost:8080)")
    var server: String?

    @Flag(name: .shortAndLong, help: "Auto-discover server on local network")
    var discover: Bool = false

    @Option(name: .shortAndLong, help: "Discovery timeout in seconds")
    var timeout: Int = 5

    @Flag(name: .shortAndLong, help: "Show detailed event information")
    var verbose: Bool = false

    mutating func validate() throws {
        // Must specify either --server or --discover
        if server == nil && !discover {
            throw ValidationError("Must specify either --server <url> or --discover")
        }

        if server != nil && discover {
            throw ValidationError("Cannot specify both --server and --discover")
        }

        guard timeout > 0 && timeout <= 60 else {
            throw ValidationError("Timeout must be between 1 and 60 seconds")
        }
    }

    @MainActor
    mutating func run() async throws {
        print("🎛️  Sendspin Controller Client")
        print("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
        print("")

        // Determine server URL
        let serverURL: URL

        if discover {
            // Auto-discover server
            print("🔍 Discovering Sendspin servers...")
            print("⏱️  Timeout: \(timeout) second\(timeout == 1 ? "" : "s")")
            print("")

            let timeoutDuration = Duration.seconds(timeout)
            let servers = await SendspinClient.discoverServers(timeout: timeoutDuration)

            if servers.isEmpty {
                print("❌ No Sendspin servers found on the local network")
                print("")
                print("💡 Tips:")
                print("   • Make sure a Sendspin server is running")
                print("   • Check that the server is on the same network")
                print("   • Verify firewall settings allow mDNS traffic")
                print("   • Try increasing the timeout with --timeout")
                throw ExitCode.failure
            }

            // Use first discovered server
            let selectedServer = servers[0]
            print("✅ Found server: \(selectedServer.name)")
            print("   URL: \(selectedServer.url)")
            print("")

            serverURL = selectedServer.url

        } else if let serverString = server {
            // Use provided server URL
            guard let url = URL(string: serverString) else {
                print("❌ Invalid server URL: \(serverString)")
                throw ExitCode.failure
            }
            serverURL = url
        } else {
            // Should never reach here due to validate()
            throw ExitCode.failure
        }

        // Create client with player role but minimal audio config
        // Note: The controller role in SendspinKit currently doesn't support sending commands
        // to OTHER players - it's designed for multi-room scenarios where the server coordinates.
        // Instead, we use the player role to get control capabilities, but we won't play audio.
        // This demonstrates "silent player" pattern - control without local audio output.
        let config = PlayerConfiguration(
            bufferCapacity: 65536, // Small buffer (we won't use it)
            supportedFormats: [
                // Minimal format support - we won't actually play audio
                AudioFormatSpec(codec: .pcm, channels: 2, sampleRate: 48_000, bitDepth: 16)
            ]
        )

        let client = SendspinClient(
            clientId: UUID().uuidString,
            name: "ControllerClient",
            roles: [.playerV1, .metadataV1],  // Player role for control + metadata for status
            playerConfig: config
        )

        // Start event monitoring task
        // Capture verbose flag before creating the task to avoid mutating self capture
        let isVerbose = verbose
        let eventTask = Task {
            await Self.monitorEvents(client: client, verbose: isVerbose)
        }

        // Connect to server
        print("🔌 Connecting to \(serverURL)...")
        do {
            try await client.connect(to: serverURL)
        } catch {
            print("❌ Connection failed: \(error.localizedDescription)")
            throw ExitCode.failure
        }

        print("✅ Connected!")
        print("")
        print("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
        print("CONTROLS:")
        print("  + / -    Increase/decrease volume by 10%")
        print("  m        Mute audio")
        print("  u        Unmute audio")
        print("  q        Quit")
        print("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
        print("")

        // Run interactive command loop
        await Self.runCommandLoop(client: client)

        // Cancel event monitoring
        eventTask.cancel()

        // Disconnect
        await client.disconnect()
        print("")
        print("👋 Disconnected from server")
    }

    /// Interactive command loop for controlling playback
    /// This demonstrates how to send control commands to players via the controller role
    @MainActor
    static func runCommandLoop(client: SendspinClient) async {
        // Track current state for display
        var currentVolume: Int = 100
        var isMuted: Bool = false

        // Display initial state
        printVolumeStatus(volume: currentVolume, muted: isMuted)

        // Enable raw mode for single-character input
        // This allows us to respond to keypresses without waiting for Enter
        let originalTermios = enableRawMode()
        defer {
            // Restore original terminal settings on exit
            if let termios = originalTermios {
                disableRawMode(termios)
            }
        }

        // Command loop - read single characters
        while true {
            // Read a single character from stdin
            // Note: In raw mode, we get characters immediately without buffering
            guard let char = readChar() else {
                continue
            }

            switch char {
            case "q", "Q":
                // Quit command
                return

            case "+", "=":
                // Increase volume by 10%
                currentVolume = min(100, currentVolume + 10)
                isMuted = false // Increasing volume unmutes

                // Convert from percentage (0-100) to float (0.0-1.0)
                let volumeFloat = Float(currentVolume) / 100.0
                await client.setVolume(volumeFloat)

                printVolumeStatus(volume: currentVolume, muted: isMuted)

            case "-", "_":
                // Decrease volume by 10%
                currentVolume = max(0, currentVolume - 10)

                // Convert from percentage (0-100) to float (0.0-1.0)
                let volumeFloat = Float(currentVolume) / 100.0
                await client.setVolume(volumeFloat)

                printVolumeStatus(volume: currentVolume, muted: isMuted)

            case "m", "M":
                // Mute audio
                isMuted = true
                await client.setMute(true)

                printVolumeStatus(volume: currentVolume, muted: isMuted)

            case "u", "U":
                // Unmute audio
                isMuted = false
                await client.setMute(false)

                printVolumeStatus(volume: currentVolume, muted: isMuted)

            default:
                // Unknown command - show help
                print("\r⚠️  Unknown command '\(char)' - press q to quit, +/- for volume, m/u for mute/unmute")
            }
        }
    }

    /// Monitor events from the client
    /// This demonstrates the async event stream pattern used throughout SendspinKit
    @MainActor
    static func monitorEvents(client: SendspinClient, verbose: Bool) async {
        // Track current state
        var currentTitle: String?
        var currentArtist: String?

        // Iterate over all events from the client
        for await event in client.events {
            switch event {
            case let .serverConnected(info):
                // Server handshake completed
                if verbose {
                    print("📡 Connected to server: \(info.name) (v\(info.version))")
                    print("   Server ID: \(info.serverId)")
                    print("")
                }

            case let .groupUpdated(info):
                // Group/session information changed
                if verbose {
                    print("👥 Group: \(info.groupName)")
                    if let state = info.playbackState {
                        print("   Playback state: \(state)")
                    }
                    print("")
                }

            case let .metadataReceived(metadata):
                // New track metadata received
                // Display track changes so controller operator knows what's playing
                let titleChanged = metadata.title != currentTitle
                let artistChanged = metadata.artist != currentArtist

                if titleChanged || artistChanged {
                    currentTitle = metadata.title
                    currentArtist = metadata.artist

                    print("\r🎵 Now Playing: \(metadata.title ?? "Unknown") - \(metadata.artist ?? "Unknown")                    ")
                }

            case let .streamStarted(format):
                // Stream started - silent player knows stream state but doesn't output audio
                if verbose {
                    let formatStr = "\(format.codec.rawValue) \(format.sampleRate)Hz " +
                        "\(format.channels)ch \(format.bitDepth)bit"
                    print("🎶 Stream started: \(formatStr)")
                    print("   (Silent player - control only, no audio output)")
                    print("")
                }

            case .streamEnded:
                // Stream ended
                if verbose {
                    print("⏹️  Stream ended")
                    print("")
                }

            case let .error(message):
                // Error occurred
                print("\r❌ Error: \(message)                    ")
                print("")

            default:
                // Ignore other events (artwork, visualizer, etc.)
                break
            }
        }

        // Event stream ended (client disconnected)
        if verbose {
            print("🔌 Disconnected from server")
        }
    }

    /// Print current volume status with visual bar
    static func printVolumeStatus(volume: Int, muted: Bool) {
        if muted {
            print("\r🔇 MUTED                                        ", terminator: "")
        } else {
            // Create a simple volume bar visualization
            let barWidth = 20
            let filled = (volume * barWidth) / 100
            let empty = barWidth - filled

            let bar = String(repeating: "█", count: filled) + String(repeating: "░", count: empty)
            print("\r🔊 Volume: [\(bar)] \(volume)%          ", terminator: "")
        }
        fflush(stdout)
    }

    /// Read a single character from stdin in raw mode
    static func readChar() -> Character? {
        var byte: UInt8 = 0
        let result = read(STDIN_FILENO, &byte, 1)

        guard result == 1 else {
            return nil
        }

        return Character(UnicodeScalar(byte))
    }

    /// Enable raw mode for terminal input (single character, no echo)
    /// Returns the original termios settings for restoration
    static func enableRawMode() -> termios? {
        var original = termios()

        // Get current terminal settings
        guard tcgetattr(STDIN_FILENO, &original) == 0 else {
            return nil
        }

        // Create modified settings for raw mode
        var raw = original

        // Disable canonical mode (line buffering) and echo
        raw.c_lflag &= ~(UInt(ICANON | ECHO))

        // Set minimum characters to read to 1
        raw.c_cc.16 = 1  // VMIN
        raw.c_cc.17 = 0  // VTIME

        // Apply raw mode settings
        guard tcsetattr(STDIN_FILENO, TCSANOW, &raw) == 0 else {
            return nil
        }

        return original
    }

    /// Restore terminal to original settings
    static func disableRawMode(_ original: termios) {
        var settings = original
        tcsetattr(STDIN_FILENO, TCSANOW, &settings)

        // Print newline to clean up terminal
        print("")
    }
}
