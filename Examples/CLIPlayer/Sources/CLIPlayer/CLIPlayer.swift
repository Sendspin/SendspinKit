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

    // Shared format list for both connect and listen modes.
    //
    // Priority-ordered: the server picks the FIRST compatible format.
    // The server does NOT match source quality — it always uses our top preference.
    //
    // Strategy: FLAC 24-bit first for maximum fidelity. FLAC compression means
    // 24-bit FLAC of a 16-bit source is barely larger than 16-bit FLAC (the extra
    // zero bits compress away), so there's no real bandwidth penalty. Standard
    // sample rates before hi-res to avoid unnecessary upsampling.
    //
    // These specs are programmer-literal constants — a validation failure here is
    // a programmer error (not a runtime input problem), so we convert throws into
    // a `preconditionFailure` at first access. This teaches the right pattern for
    // static config built from library types that validate in their initializer.
    private static let supportedFormats: [AudioFormatSpec] = {
        do {
            return [
                // FLAC 24-bit — preferred (lossless, no quality loss on any source)
                try AudioFormatSpec(codec: .flac, channels: 2, sampleRate: 44_100, bitDepth: 24),
                try AudioFormatSpec(codec: .flac, channels: 2, sampleRate: 48_000, bitDepth: 24),
                try AudioFormatSpec(codec: .flac, channels: 2, sampleRate: 88_200, bitDepth: 24),
                try AudioFormatSpec(codec: .flac, channels: 2, sampleRate: 96_000, bitDepth: 24),
                // FLAC 16-bit — fallback if server can't do 24-bit FLAC
                try AudioFormatSpec(codec: .flac, channels: 2, sampleRate: 44_100, bitDepth: 16),
                try AudioFormatSpec(codec: .flac, channels: 2, sampleRate: 48_000, bitDepth: 16),
                // PCM fallbacks if server can't do FLAC
                try AudioFormatSpec(codec: .pcm, channels: 2, sampleRate: 44_100, bitDepth: 16),
                try AudioFormatSpec(codec: .pcm, channels: 2, sampleRate: 48_000, bitDepth: 16),
                try AudioFormatSpec(codec: .pcm, channels: 2, sampleRate: 88_200, bitDepth: 24),
                try AudioFormatSpec(codec: .pcm, channels: 2, sampleRate: 96_000, bitDepth: 24),
                try AudioFormatSpec(codec: .pcm, channels: 2, sampleRate: 176_400, bitDepth: 24),
                try AudioFormatSpec(codec: .pcm, channels: 2, sampleRate: 192_000, bitDepth: 24),
                // Lossy compressed — lowest bandwidth option
                try AudioFormatSpec(codec: .opus, channels: 2, sampleRate: 48_000, bitDepth: 16)
            ]
        } catch {
            preconditionFailure("CLIPlayer supportedFormats contains an invalid spec: \(error)")
        }
    }()

    private static func playerConfig(volumeMode: VolumeMode) throws -> PlayerConfiguration {
        try PlayerConfiguration(
            bufferCapacity: 2_097_152, // 2MB buffer
            supportedFormats: supportedFormats,
            volumeMode: volumeMode
        )
    }

    private static let artworkConfig: ArtworkConfiguration = {
        do {
            return try ArtworkConfiguration(channels: [
                ArtworkChannel(source: .album, format: .jpeg, mediaWidth: 800, mediaHeight: 800)
            ])
        } catch {
            preconditionFailure("CLIPlayer artworkConfig is invalid: \(error)")
        }
    }()

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
        let config = try Self.playerConfig(volumeMode: volumeMode)
        let client = try SendspinClient(
            clientId: UUID().uuidString,
            name: clientName,
            roles: [.playerV1, .metadataV1, .controllerV1, .artworkV1],
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
            await display.start(client: client)
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
        // `client.events` is kept alive by SendspinClient across reconnects,
        // so we can't wait for the stream to finish naturally — we have to
        // break out of the for-await explicitly on `.disconnected`.
        eventLoop: for await event in client.events {
            if useTUI {
                await handleEventTUI(event)
            } else {
                handleEventLog(event)
            }
            if case .disconnected = event {
                disconnectedContinuation.yield()
                disconnectedContinuation.finish()
                break eventLoop
            }
        }
        // Fallback: if the loop exits via cancellation or client deallocation,
        // make sure the continuation is also finished so no one waits forever.
        disconnectedContinuation.yield()
        disconnectedContinuation.finish()
    }

    /// Handle events in TUI mode by pushing state updates into the StatusDisplay.
    ///
    /// Every ``ClientEvent`` case is listed explicitly — events the TUI doesn't
    /// render still appear in an `ignored` block. If `ClientEvent` gains a new
    /// case, this switch fails to compile, forcing a decision about whether
    /// the TUI should show it.
    @MainActor
    private func handleEventTUI(_ event: ClientEvent) async {
        switch event {
        case let .serverConnected(info):
            await display.updateServer(name: info.name)

        case let .streamStarted(format), let .streamFormatChanged(format):
            await display.updateStream(format: Self.formatString(format))

        case .streamEnded:
            await display.updateStream(format: "No stream")

        case let .metadataReceived(metadata):
            await display.updateMetadata(
                title: metadata.title,
                artist: metadata.artist,
                album: metadata.album,
                artworkUrl: metadata.artworkURL
            )

        // Ignored in TUI mode — these are either handled by log mode only, or
        // have no corresponding on-screen element yet. Keep the list explicit
        // so adding a new case is a compiler error, not a silent drop.
        case .groupUpdated,
             .controllerStateUpdated,
             .artworkStreamStarted,
             .artworkReceived,
             .visualizerData,
             .streamCleared,
             .staticDelayChanged,
             .lastPlayedServerChanged,
             .rawAudioChunk,
             .disconnected:
            break
        }
    }

    /// Handle events in log mode by printing a tagged line to stdout.
    /// Not `@MainActor`-isolated — printing to stdout needs no isolation.
    private nonisolated func handleEventLog(_ event: ClientEvent) {
        switch event {
        case let .serverConnected(info):
            print("[EVENT] Server connected: \(info.name) (v\(info.version))")

        case let .streamStarted(format):
            print("[EVENT] Stream started: \(Self.formatString(format))")

        case let .streamFormatChanged(format):
            print("[EVENT] Format changed: \(Self.formatString(format))")

        case .streamEnded:
            print("[EVENT] Stream ended")

        case let .groupUpdated(info):
            print("[EVENT] Group updated: \(info.groupName) (\(info.playbackState?.rawValue ?? "unknown"))")

        case let .metadataReceived(metadata):
            print("[METADATA] Track: \(metadata.title ?? "unknown")")
            print("[METADATA] Artist: \(metadata.artist ?? "unknown")")
            print("[METADATA] Album: \(metadata.album ?? "unknown")")
            if let artworkUrl = metadata.artworkURL {
                print("[METADATA] Artwork URL: \(artworkUrl)")
            }

        case let .controllerStateUpdated(state):
            let cmds = state.supportedCommands.map(\.rawValue).joined(separator: ",")
            print("[CONTROLLER] commands=\(cmds) volume=\(state.volume) muted=\(state.muted)")

        case let .artworkStreamStarted(channels):
            let desc = channels.enumerated()
                .map { "ch\($0): \($1.source)/\($1.format) \($1.width)x\($1.height)" }
                .joined(separator: ", ")
            print("[EVENT] Artwork stream started: \(desc)")

        case let .artworkReceived(channel, data):
            if data.isEmpty {
                print("[EVENT] Artwork cleared on channel \(channel)")
            } else {
                print("[EVENT] Artwork received on channel \(channel): \(data.count) bytes")
            }

        case let .visualizerData(data):
            print("[EVENT] Visualizer data: \(data.count) bytes")

        case .streamCleared:
            print("[EVENT] Stream cleared (seek)")

        case let .staticDelayChanged(delayMs):
            print("[EVENT] Static delay changed: \(delayMs)ms")

        case let .lastPlayedServerChanged(serverId):
            print("[EVENT] Last played server: \(serverId)")

        case let .disconnected(reason):
            print("[EVENT] Disconnected: \(reason)")

        case .rawAudioChunk:
            break // Raw audio passthrough; CLIPlayer uses the decoded pipeline
        }
    }

    /// Format an `AudioFormatSpec` for single-line display. Shared between TUI
    /// and log modes — static + nonisolated so it can be called from either.
    nonisolated static func formatString(_ format: AudioFormatSpec) -> String {
        "\(format.codec.rawValue) \(format.sampleRate)Hz \(format.channels)ch \(format.bitDepth)bit"
    }

    /// Run a throwing async body and log the error to stderr if it fails.
    private nonisolated static func attempt(_ body: () async throws -> Void) async {
        do {
            try await body()
        } catch {
            fputs("[ERROR] \(error.localizedDescription)\n", stderr)
        }
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
                await attempt { try await client.setVolume(volume) }
                await display?.updateVolume(volume, muted: false)

            case "m", "mute":
                await attempt { try await client.setMute(true) }
                await display?.updateVolume(100, muted: true)

            case "u", "unmute":
                await attempt { try await client.setMute(false) }
                await display?.updateVolume(100, muted: false)

            // Controller commands
            case "p", "play":
                await attempt { try await client.play() }
            case "pause":
                await attempt { try await client.pause() }
            case "s", "stop":
                await attempt { try await client.stopPlayback() }
            case "n", "next":
                await attempt { try await client.next() }
            case "b", "prev", "previous":
                await attempt { try await client.previous() }
            case "gv":
                guard parts.count > 1, let vol = Int(parts[1]) else { continue }
                await attempt { try await client.setGroupVolume(vol) }
            case "gm":
                await attempt { try await client.setGroupMute(true) }
            case "gu":
                await attempt { try await client.setGroupMute(false) }

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
            if let parsedCodec = AudioCodec(rawValue: str) {
                codec = parsedCodec
            } else if let num = Int(str) {
                // Heuristic: sample rates are > 1000, bit depths are <= 32
                if num > 32 {
                    sampleRate = num
                } else {
                    bitDepth = num
                }
            }
        }

        if codec == nil && sampleRate == nil && bitDepth == nil {
            fputs("[FORMAT] Usage: f [codec] [sampleRate] [bitDepth]\n", stderr)
            fputs("[FORMAT] Examples: f flac, f flac 48000, f pcm 44100 16\n", stderr)
            return
        }

        let codecStr = codec?.rawValue ?? "auto"
        let rateStr = sampleRate.map(String.init) ?? "auto"
        let bitsStr = bitDepth.map(String.init) ?? "auto"
        fputs("[FORMAT] Requesting: codec=\(codecStr) rate=\(rateStr) bits=\(bitsStr)\n", stderr)
        await attempt {
            try await client.requestPlayerFormat(
                codec: codec,
                sampleRate: sampleRate,
                bitDepth: bitDepth
            )
        }
    }

    /// Listen for incoming server connections (server-initiated path).
    /// Advertises via mDNS and waits for servers to connect.
    @MainActor
    func listen(port: UInt16, clientName: String, useTUI: Bool = true, volumeMode: VolumeMode = .software) async throws {
        print("🎵 Sendspin CLI Player (Listen Mode)")
        print("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
        print("Advertising on port \(port)...")

        let config = try Self.playerConfig(volumeMode: volumeMode)
        let client = try SendspinClient(
            clientId: UUID().uuidString,
            name: clientName,
            roles: [.playerV1, .metadataV1, .controllerV1, .artworkV1],
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
            await display.start(client: client)
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
    private var clockSamples: Int64 = 0
    /// Nil until the first accepted sample — mirrors the optional return of
    /// `currentClockSyncStats()` so "no data yet" has a single representation.
    private var clockQuality: ClockSyncQuality?
    private var volume: Int = 100
    private var isMuted: Bool = false
    private var uptime: TimeInterval = 0
    private let startTime = Date()
    private weak var client: SendspinClient?

    init() {}

    /// Start the display loop, polling `client.currentClockSyncStats()` each tick
    /// to keep the clock sync section live.
    func start(client: SendspinClient? = nil) {
        guard !isRunning else { return }
        isRunning = true
        self.client = client

        // Hide cursor and clear screen
        print(ANSI.hideCursor, terminator: "")
        print(ANSI.clearScreen, terminator: "")
        fflush(stdout)

        displayTask = Task {
            while !Task.isCancelled && isRunning {
                await pollClockSync()
                render()
                try? await Task.sleep(for: .milliseconds(100))
            }
        }
    }

    /// Fetch clock sync stats from the client and update local display state.
    /// Uses ``ClockSyncStats/quality`` so the tier buckets match every other
    /// SendspinKit consumer — no locally-defined thresholds.
    private func pollClockSync() async {
        guard let client else { return }
        if let stats = await client.currentClockSyncStats() {
            clockOffset = stats.offset
            clockRTT = stats.rtt
            clockSamples = stats.sampleCount
            clockQuality = stats.quality
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

        // Clock sync — label and color are derived from the public ClockSyncQuality
        // enum so every SendspinKit consumer agrees on what "good" means.
        let (qualityLabel, qualityColor): (String, String) = {
            guard let quality = clockQuality else { return ("waiting", ANSI.yellow) }
            switch quality {
            case .excellent:    return ("excellent", ANSI.green)
            case .good:         return ("good", ANSI.green)
            case .fair:         return ("fair", ANSI.yellow)
            case .poor:         return ("poor", ANSI.yellow)
            case .unacceptable: return ("unacceptable", ANSI.red)
            }
        }()
        output += "\(ANSI.bold)CLOCK SYNC\(ANSI.reset)\n"
        output += "  Offset:  \(formatMicroseconds(clockOffset))\n"
        output += "  RTT:     \(formatMicroseconds(clockRTT))\n"
        output += "  Samples: \(clockSamples)\n"
        output += "  Quality: \(qualityColor)\(qualityLabel)\(ANSI.reset)\n"
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
