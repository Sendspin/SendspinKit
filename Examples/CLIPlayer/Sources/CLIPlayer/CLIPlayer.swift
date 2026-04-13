// ABOUTME: Example CLI player demonstrating SendspinKit usage
// ABOUTME: Connects to a Sendspin server and plays synchronized audio

import Foundation
import SendspinKit

/// Simple CLI player for Sendspin Protocol
final class CLIPlayer {
    private var client: SendspinClient?
    private var eventTask: Task<Void, Never>?
    private let display = StatusDisplay()
    /// Signals that the connection has ended and the process should exit.
    private let disconnected: AsyncStream<Void>
    private let disconnectedContinuation: AsyncStream<Void>.Continuation

    init() {
        (disconnected, disconnectedContinuation) = AsyncStream.makeStream()
    }

    /// Shared player configuration for both connect and listen modes.
    ///
    /// Format list is priority-ordered: the server picks the FIRST compatible format.
    /// The server does NOT match source quality — it always uses our top preference.
    ///
    /// Strategy: FLAC 24-bit first for maximum fidelity. FLAC compression means
    /// 24-bit FLAC of a 16-bit source is barely larger than 16-bit FLAC (the extra
    /// zero bits compress away), so there's no real bandwidth penalty. Standard
    /// sample rates before hi-res to avoid unnecessary upsampling.
    /// Shared format list for both connect and listen modes.
    ///
    /// Priority-ordered: the server picks the FIRST compatible format.
    /// FLAC 24-bit first for maximum fidelity. Standard sample rates before hi-res.
    private static let supportedFormats = [
        // FLAC 24-bit — preferred (lossless, no quality loss on any source)
        AudioFormatSpec(codec: .flac, channels: 2, sampleRate: 44_100, bitDepth: 24),
        AudioFormatSpec(codec: .flac, channels: 2, sampleRate: 48_000, bitDepth: 24),
        AudioFormatSpec(codec: .flac, channels: 2, sampleRate: 88_200, bitDepth: 24),
        AudioFormatSpec(codec: .flac, channels: 2, sampleRate: 96_000, bitDepth: 24),
        // FLAC 16-bit — fallback if server can't do 24-bit FLAC
        AudioFormatSpec(codec: .flac, channels: 2, sampleRate: 44_100, bitDepth: 16),
        AudioFormatSpec(codec: .flac, channels: 2, sampleRate: 48_000, bitDepth: 16),
        // PCM fallbacks if server can't do FLAC
        AudioFormatSpec(codec: .pcm, channels: 2, sampleRate: 44_100, bitDepth: 16),
        AudioFormatSpec(codec: .pcm, channels: 2, sampleRate: 48_000, bitDepth: 16),
        AudioFormatSpec(codec: .pcm, channels: 2, sampleRate: 88_200, bitDepth: 24),
        AudioFormatSpec(codec: .pcm, channels: 2, sampleRate: 96_000, bitDepth: 24),
        AudioFormatSpec(codec: .pcm, channels: 2, sampleRate: 176_400, bitDepth: 24),
        AudioFormatSpec(codec: .pcm, channels: 2, sampleRate: 192_000, bitDepth: 24),
        // Lossy compressed — lowest bandwidth option
        AudioFormatSpec(codec: .opus, channels: 2, sampleRate: 48_000, bitDepth: 16),
    ]

    private static func playerConfig(volumeMode: VolumeMode) -> PlayerConfiguration {
        PlayerConfiguration(
            bufferCapacity: 2_097_152, // 2MB buffer
            supportedFormats: supportedFormats,
            volumeMode: volumeMode
        )
    }

    private static let artworkConfig = ArtworkConfiguration(channels: [
        ArtworkChannel(source: .album, format: .jpeg, mediaWidth: 800, mediaHeight: 800),
    ])

    @MainActor
    func run(serverURL: String, clientName: String, useTUI: Bool = true, volumeMode: VolumeMode = .software) async throws {
        // Simple startup banner before TUI takes over
        print("🎵 Sendspin CLI Player")
        print("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
        print("Initializing...")

        // Parse URL
        guard let url = URL(string: serverURL) else {
            print("❌ Invalid server URL: \(serverURL)")
            throw CLIPlayerError.invalidURL
        }

        // Create client
        let config = Self.playerConfig(volumeMode: volumeMode)
        let client = SendspinClient(
            clientId: UUID().uuidString,
            name: clientName,
            roles: [.player, .metadata, .controller, .artwork],
            playerConfig: config,
            artworkConfig: Self.artworkConfig
        )
        self.client = client

        fputs("[CONFIG] Volume mode: \(volumeMode)\n", stderr)

        // Start event monitoring
        eventTask = Task {
            await monitorEvents(client: client, useTUI: useTUI)
        }

        // Connect to server
        try await client.connect(to: url)

        // Small delay to let initial messages settle
        try? await Task.sleep(for: .milliseconds(500))

        if useTUI {
            await display.start()
        } else {
            print("✅ Connected! Logging mode (type 'help' for commands, Ctrl-C to exit)")
            print("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
        }

        // Start the stdin command loop (fire-and-forget — it's optional input,
        // not the lifecycle owner). If stdin is EOF (piped from /dev/null, running
        // under `timeout`, etc.) this task exits immediately and harmlessly.
        Task.detached { [display] in
            await CLIPlayer.runCommandLoopStatic(client: client, display: useTUI ? display : nil)
        }

        // Stay alive until the connection drops. monitorEvents signals this
        // when it sees a .disconnected event.
        for await _ in disconnected { break }

        if useTUI {
            await display.stop()
        }
    }

    @MainActor
    private func monitorEvents(client: SendspinClient, useTUI: Bool) async {
        for await event in client.events {
            switch event {
            case let .serverConnected(info):
                if useTUI {
                    await display.updateServer(name: info.name)
                } else {
                    print("[EVENT] Server connected: \(info.name) (v\(info.version))")
                }

            case let .streamStarted(format):
                let formatStr = "\(format.codec.rawValue) \(format.sampleRate)Hz " +
                    "\(format.channels)ch \(format.bitDepth)bit"
                if useTUI {
                    await display.updateStream(format: formatStr)
                } else {
                    print("[EVENT] Stream started: \(formatStr)")
                }

            case let .streamFormatChanged(format):
                let formatStr = "\(format.codec.rawValue) \(format.sampleRate)Hz " +
                    "\(format.channels)ch \(format.bitDepth)bit"
                if useTUI {
                    await display.updateStream(format: formatStr)
                } else {
                    print("[EVENT] Format changed: \(formatStr)")
                }

            case .streamEnded:
                if useTUI {
                    await display.updateStream(format: "No stream")
                } else {
                    print("[EVENT] Stream ended")
                }

            case let .groupUpdated(info):
                if !useTUI {
                    print("[EVENT] Group updated: \(info.groupName) (\(info.playbackState?.rawValue ?? "unknown"))")
                }

            case let .metadataReceived(metadata):
                if useTUI {
                    await display.updateMetadata(
                        title: metadata.title,
                        artist: metadata.artist,
                        album: metadata.album,
                        artworkUrl: metadata.artworkURL
                    )
                } else {
                    print("[METADATA] Track: \(metadata.title ?? "unknown")")
                    print("[METADATA] Artist: \(metadata.artist ?? "unknown")")
                    print("[METADATA] Album: \(metadata.album ?? "unknown")")
                    if let artworkUrl = metadata.artworkURL {
                        print("[METADATA] Artwork URL: \(artworkUrl)")
                    }
                }

            case let .controllerStateUpdated(state):
                if !useTUI {
                    let cmds = state.supportedCommands.map(\.rawValue).joined(separator: ",")
                    print("[CONTROLLER] commands=\(cmds) volume=\(state.volume) muted=\(state.muted)")
                }

            case let .artworkStreamStarted(channels):
                if !useTUI {
                    let desc = channels.enumerated().map { "ch\($0): \($1.source)/\($1.format) \($1.width)x\($1.height)" }.joined(separator: ", ")
                    print("[EVENT] Artwork stream started: \(desc)")
                }

            case let .artworkReceived(channel, data):
                if !useTUI {
                    if data.isEmpty {
                        print("[EVENT] Artwork cleared on channel \(channel)")
                    } else {
                        print("[EVENT] Artwork received on channel \(channel): \(data.count) bytes")
                    }
                }

            case let .visualizerData(data):
                if !useTUI {
                    print("[EVENT] Visualizer data: \(data.count) bytes")
                }

            case let .staticDelayChanged(delayMs):
                if !useTUI {
                    print("[EVENT] Static delay changed: \(delayMs)ms")
                }

            case let .disconnected(reason):
                if !useTUI {
                    print("[EVENT] Disconnected: \(reason)")
                }
                disconnectedContinuation.yield()
                disconnectedContinuation.finish()

            }
        }
        // Event stream ended (client deallocated or connection dropped)
        disconnectedContinuation.yield()
        disconnectedContinuation.finish()
    }

    private nonisolated static func runCommandLoopStatic(client: SendspinClient, display: StatusDisplay?) async {
        while let line = readLine() {
            let trimmedLine = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmedLine.isEmpty else {
                continue
            }

            let parts = line.split(separator: " ")
            guard let command = parts.first else { continue }

            switch command.lowercased() {
            case "q", "quit", "exit":
                await client.disconnect()
                return

            case "?", "h", "help":
                fputs("Commands: [p]lay [pause] [n]ext [b]ack [s]top [v 0-100] [m]ute [u]nmute [f codec rate bits] [q]uit\n", stderr)
                fputs("Format:   f flac | f flac 48000 | f pcm 44100 16 | f opus\n", stderr)

            case "v", "volume":
                guard parts.count > 1, let volume = Int(parts[1]) else {
                    continue
                }
                await client.setVolume(volume)
                await display?.updateVolume(volume, muted: false)

            case "m", "mute":
                await client.setMute(true)
                await display?.updateVolume(100, muted: true)

            case "u", "unmute":
                await client.setMute(false)
                await display?.updateVolume(100, muted: false)

            // Controller commands
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
            case "gv":
                guard parts.count > 1, let vol = Int(parts[1]) else { continue }
                await client.setGroupVolume(vol)
            case "gm":
                await client.setGroupMute(true)
            case "gu":
                await client.setGroupMute(false)

            // Format request: "f flac 48000 24" or partial: "f flac" or "f pcm 44100"
            case "f", "format":
                await handleFormatRequest(parts: parts, client: client)

            default:
                break // Ignore unknown commands
            }
        }
    }

    /// Parse and send a format request from CLI input.
    /// Syntax: `f [codec] [sampleRate] [bitDepth]` — all optional.
    /// Examples: `f flac`, `f flac 48000`, `f pcm 44100 16`, `f opus`
    private nonisolated static func handleFormatRequest(
        parts: [Substring],
        client: SendspinClient
    ) async {
        var codec: AudioCodec?
        var sampleRate: Int?
        var bitDepth: Int?

        for part in parts.dropFirst() {
            let str = String(part).lowercased()
            if let c = AudioCodec(rawValue: str) {
                codec = c
            } else if let n = Int(str) {
                // Heuristic: sample rates are > 1000, bit depths are <= 32
                if n > 32 {
                    sampleRate = n
                } else {
                    bitDepth = n
                }
            }
        }

        if codec == nil && sampleRate == nil && bitDepth == nil {
            fputs("[FORMAT] Usage: f [codec] [sampleRate] [bitDepth]\n", stderr)
            fputs("[FORMAT] Examples: f flac, f flac 48000, f pcm 44100 16\n", stderr)
            return
        }

        fputs("[FORMAT] Requesting: codec=\(codec?.rawValue ?? "auto") rate=\(sampleRate.map(String.init) ?? "auto") bits=\(bitDepth.map(String.init) ?? "auto")\n", stderr)
        await client.requestPlayerFormat(
            codec: codec,
            sampleRate: sampleRate,
            bitDepth: bitDepth
        )
    }

    /// Listen for incoming server connections (server-initiated path).
    /// Advertises via mDNS and waits for servers to connect.
    @MainActor
    func listen(port: UInt16, clientName: String, useTUI: Bool = true, volumeMode: VolumeMode = .software) async throws {
        print("🎵 Sendspin CLI Player (Listen Mode)")
        print("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
        print("Advertising on port \(port)...")

        let config = Self.playerConfig(volumeMode: volumeMode)
        let client = SendspinClient(
            clientId: UUID().uuidString,
            name: clientName,
            roles: [.player, .metadata, .controller, .artwork],
            playerConfig: config,
            artworkConfig: Self.artworkConfig
        )
        self.client = client

        // Start event monitoring
        eventTask = Task {
            await monitorEvents(client: client, useTUI: useTUI)
        }

        // Start the advertiser
        let advertiser = ClientAdvertiser(name: clientName, port: port)
        try await advertiser.start()

        print("✅ Advertising as '\(clientName)' on port \(port)")
        print("   Waiting for servers to connect...")
        if !useTUI {
            print("   Type 'help' for commands, Ctrl-C to exit")
        }
        print("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")

        if useTUI {
            await display.start()
        }

        // Fire-and-forget stdin command loop
        Task.detached { [display] in
            await CLIPlayer.runCommandLoopStatic(client: client, display: useTUI ? display : nil)
        }

        // Accept incoming server connections (runs until advertiser stops)
        for await transport in advertiser.connections {
            fputs("[LISTEN] Server connected via transport, running handshake...\n", stderr)
            do {
                try await client.acceptConnection(transport)
                fputs("[LISTEN] Handshake complete\n", stderr)
            } catch {
                fputs("[LISTEN] Connection failed: \(error)\n", stderr)
            }
        }

        if useTUI {
            await display.stop()
        }
    }

    /// Graceful shutdown: disconnect with reason, clean up resources.
    /// Called from the SIGINT handler for clean Ctrl-C behavior.
    @MainActor
    func gracefulShutdown() async {
        if let client = client {
            await client.disconnect(reason: .shutdown)
        }
        eventTask?.cancel()
    }

    deinit {
        eventTask?.cancel()
        // Disconnect client on cleanup
        Task { @MainActor [weak client] in
            await client?.disconnect()
        }
    }
}

enum CLIPlayerError: Error {
    case invalidURL
}

// MARK: - Terminal UI

/// ANSI terminal control codes
enum ANSI {
    static let clearScreen = "\u{001B}[2J"
    static let home = "\u{001B}[H"
    static let hideCursor = "\u{001B}[?25l"
    static let showCursor = "\u{001B}[?25h"
    static let saveCursor = "\u{001B}[s"
    static let restoreCursor = "\u{001B}[u"

    // Colors
    static let reset = "\u{001B}[0m"
    static let bold = "\u{001B}[1m"
    static let dim = "\u{001B}[2m"
    static let green = "\u{001B}[32m"
    static let yellow = "\u{001B}[33m"
    static let blue = "\u{001B}[34m"
    static let magenta = "\u{001B}[35m"
    static let cyan = "\u{001B}[36m"
    static let red = "\u{001B}[31m"

    static func moveTo(row: Int, col: Int) -> String {
        return "\u{001B}[\(row);\(col)H"
    }
}

/// Live-updating status display for the CLI player
actor StatusDisplay {
    private var displayTask: Task<Void, Never>?
    private var isRunning = false

    // State
    private var serverName: String = "Not connected"
    private var streamFormat: String = "No stream"
    private var trackTitle: String?
    private var trackArtist: String?
    private var trackAlbum: String?
    private var trackArtworkUrl: String?
    private var clockOffset: Int64 = 0
    private var clockRTT: Int64 = 0
    private var clockQuality: String = "lost"
    private var chunksReceived: Int = 0
    private var chunksPlayed: Int = 0
    private var chunksDropped: Int = 0
    private var bufferMs: Double = 0.0
    private var volume: Int = 100
    private var isMuted: Bool = false
    private var uptime: TimeInterval = 0
    private let startTime = Date()

    init() {}

    func start() {
        guard !isRunning else { return }
        isRunning = true

        // Hide cursor and clear screen
        print(ANSI.hideCursor, terminator: "")
        print(ANSI.clearScreen, terminator: "")
        fflush(stdout)

        displayTask = Task {
            while !Task.isCancelled && isRunning {
                render()
                try? await Task.sleep(for: .milliseconds(100))
            }
        }
    }

    func stop() {
        isRunning = false
        displayTask?.cancel()
        displayTask = nil

        // Show cursor
        print(ANSI.showCursor, terminator: "")
        fflush(stdout)
    }

    // Update methods
    func updateServer(name: String) {
        serverName = name
    }

    func updateStream(format: String) {
        streamFormat = format
    }

    func updateClock(offset: Int64, rtt: Int64, quality: String) {
        clockOffset = offset
        clockRTT = rtt
        clockQuality = quality
    }

    func updateStats(received: Int, played: Int, dropped: Int, bufferMs: Double) {
        chunksReceived = received
        chunksPlayed = played
        chunksDropped = dropped
        self.bufferMs = bufferMs
    }

    func updateVolume(_ vol: Int, muted: Bool) {
        volume = vol
        isMuted = muted
    }

    func updateMetadata(title: String?, artist: String?, album: String?, artworkUrl: String?) {
        trackTitle = title
        trackArtist = artist
        trackAlbum = album
        trackArtworkUrl = artworkUrl
    }

    private func render() {
        uptime = Date().timeIntervalSince(startTime)

        var output = ANSI.home

        // Header
        output += "\(ANSI.bold)\(ANSI.cyan)"
        output += "┏━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━┓\n"
        output += "┃                      🎵 SENDSPIN CLI PLAYER 🎵                          ┃\n"
        output += "┗━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━┛\n"
        output += ANSI.reset
        output += "\n"

        // Connection info
        output += "\(ANSI.bold)CONNECTION\(ANSI.reset)\n"
        output += "  Server:  \(ANSI.green)\(serverName)\(ANSI.reset)\n"
        output += "  Uptime:  \(formatDuration(uptime))\n"
        output += "\n"

        // Stream info
        output += "\(ANSI.bold)STREAM\(ANSI.reset)\n"
        output += "  Format:  \(ANSI.blue)\(streamFormat)\(ANSI.reset)\n"
        if let title = trackTitle {
            output += "  Track:   \(ANSI.magenta)\(title)\(ANSI.reset)\n"
        }
        if let artist = trackArtist {
            output += "  Artist:  \(artist)\n"
        }
        if let album = trackAlbum {
            output += "  Album:   \(album)\n"
        }
        if let artworkUrl = trackArtworkUrl {
            output += "  Artwork: \(ANSI.dim)\(artworkUrl)\(ANSI.reset)\n"
        }
        output += "\n"

        // Clock sync
        let qualityColor = clockQuality == "good" ? ANSI.green : (clockQuality == "degraded" ? ANSI.yellow : ANSI.red)
        output += "\(ANSI.bold)CLOCK SYNC\(ANSI.reset)\n"
        output += "  Offset:  \(formatMicroseconds(clockOffset))\n"
        output += "  RTT:     \(formatMicroseconds(clockRTT))\n"
        output += "  Quality: \(qualityColor)\(clockQuality)\(ANSI.reset)\n"
        output += "\n"

        // Playback stats
        output += "\(ANSI.bold)PLAYBACK\(ANSI.reset)\n"
        output += "  Received: \(ANSI.cyan)\(chunksReceived)\(ANSI.reset) chunks\n"
        output += "  Played:   \(ANSI.green)\(chunksPlayed)\(ANSI.reset) chunks\n"
        output += "  Dropped:  \(chunksDropped > 0 ? ANSI.red : ANSI.dim)\(chunksDropped)\(ANSI.reset) chunks\n"
        output += "  Buffer:   \(formatBuffer(bufferMs))\n"
        output += "\n"

        // Volume
        output += "\(ANSI.bold)AUDIO\(ANSI.reset)\n"
        let volumeBar = makeVolumeBar(volume: volume, muted: isMuted)
        output += "  Volume:  \(volumeBar)\n"
        output += "\n"

        // Commands
        output += "\(ANSI.dim)━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\(ANSI.reset)\n"
        output += "\(ANSI.dim)Commands: [p]lay [pause] [n]ext [b]ack [s]top  [v <0-100>] [m]ute [u]nmute [f]ormat [q]uit\(ANSI.reset)\n"
        output += "\(ANSI.dim)━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\(ANSI.reset)\n"
        output += "> "

        print(output, terminator: "")
        fflush(stdout)
    }

    private func formatDuration(_ seconds: TimeInterval) -> String {
        let hours = Int(seconds) / 3600
        let minutes = (Int(seconds) % 3600) / 60
        let secs = Int(seconds) % 60

        if hours > 0 {
            return String(format: "%02d:%02d:%02d", hours, minutes, secs)
        } else {
            return String(format: "%02d:%02d", minutes, secs)
        }
    }

    private func formatMicroseconds(_ microseconds: Int64) -> String {
        let absMicroseconds = abs(microseconds)

        if absMicroseconds < 1000 {
            return "\(microseconds)μs"
        } else if absMicroseconds < 1_000_000 {
            let milliseconds = Double(microseconds) / 1000.0
            return String(format: "%.1fms", milliseconds)
        } else {
            let seconds = Double(microseconds) / 1_000_000.0
            return String(format: "%.2fs", seconds)
        }
    }

    private func formatBuffer(_ milliseconds: Double) -> String {
        let color = milliseconds < 50 ? ANSI.red : (milliseconds < 100 ? ANSI.yellow : ANSI.green)
        return "\(color)\(String(format: "%.1fms", milliseconds))\(ANSI.reset)"
    }

    private func makeVolumeBar(volume: Int, muted: Bool) -> String {
        if muted {
            return "\(ANSI.red)🔇 MUTED\(ANSI.reset)"
        }

        let barWidth = 20
        let filled = (volume * barWidth) / 100
        let empty = barWidth - filled

        let bar = String(repeating: "█", count: filled) + String(repeating: "░", count: empty)
        let color = volume > 80 ? ANSI.green : (volume > 40 ? ANSI.yellow : ANSI.red)

        return "\(color)\(bar)\(ANSI.reset) \(volume)%"
    }
}
