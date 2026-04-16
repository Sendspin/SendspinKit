// ABOUTME: Display-only metadata client — no audio playback
// ABOUTME: Connects to a Sendspin server and prints every metadata/group/stream event

import ArgumentParser
import Dispatch
import Foundation
import SendspinKit

// MARK: - URL resolution helper

private func resolveServerURL(server: String?, discover: Bool, timeout: Double) async throws -> URL {
    if let server {
        guard let url = URL(string: server) else {
            throw ValidationError("Invalid server URL: \(server)")
        }
        return url
    }
    if discover {
        print("Discovering Sendspin servers (\(timeout)s timeout)...")
        // Preserve fractional seconds — `.seconds(Int(timeout))` would truncate
        // `--timeout 2.5` to 2.0. `.milliseconds` is whole-number friendly.
        let servers = try await SendspinClient.discoverServers(
            timeout: .milliseconds(Int(timeout * 1000))
        )
        guard let first = servers.first else {
            throw ValidationError("No servers found via mDNS discovery")
        }
        print("Connecting to: \(first.name) at \(first.url)\n")
        return first.url
    }
    throw ValidationError("Provide --server <url> or --discover")
}

// MARK: - Command

@main
struct MetadataClient: AsyncParsableCommand {

    static let configuration = CommandConfiguration(
        commandName: "MetadataClient",
        abstract: "Connect to a Sendspin server and display metadata events (no audio playback)."
    )

    @Option(name: .long, help: "Server WebSocket URL (e.g. ws://192.168.1.5:8927).")
    var server: String?

    @Flag(name: .long, help: "Auto-discover a server via mDNS instead of specifying --server.")
    var discover: Bool = false

    @Option(name: .long, help: "mDNS discovery timeout in seconds (used with --discover).")
    var timeout: Double = 5.0

    @MainActor
    func run() async throws {
        let url = try await resolveServerURL(
            server: server,
            discover: discover,
            timeout: timeout
        )

        // Build the client. We only request the metadata role — no playerConfig
        // needed because we are not playing audio. The server will send us
        // track metadata, group updates, and stream lifecycle events.
        let client = try SendspinClient(
            clientId: "metadata-example",
            name: "Metadata Client",
            roles: [.metadataV1]
        )

        // MARK: SIGINT handling
        // Ignore the default handler so Ctrl-C doesn't kill us mid-async-loop.
        // Instead, dispatch a graceful disconnect and let the event loop exit naturally.
        signal(SIGINT, SIG_IGN)
        let sigintSource = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
        sigintSource.setEventHandler {
            print("\nShutting down...")
            Task { await client.disconnect() }
        }
        sigintSource.resume()

        // Connect — throws if the transport can't reach the server.
        try await client.connect(to: url)
        print("Connected. Waiting for events (Ctrl-C to quit).\n")

        // MARK: Event loop
        // client.events is an AsyncStream<ClientEvent>. It ends when disconnect()
        // is called (either by us in the SIGINT handler or by .disconnected below).
        for await event in client.events {
            switch event {

            // MARK: serverConnected
            // Fired once after the handshake completes. Contains the server's
            // identity and the set of roles the server actually activated.
            case .serverConnected(let info):
                print("--- Server Connected ---")
                print("  Name:      \(info.name)")
                print("  Version:   \(info.version)")
                print("  Server ID: \(info.serverId)")
                print("")

            // MARK: metadataReceived
            // Fired whenever track metadata changes. The server sends deltas,
            // but SendspinKit accumulates them so every event is the full picture.
            case .metadataReceived(let metadata):
                print("--- Metadata ---")
                if let title = metadata.title {
                    print("  Title:        \(title)")
                }
                if let artist = metadata.artist {
                    print("  Artist:       \(artist)")
                }
                if let album = metadata.album {
                    print("  Album:        \(album)")
                }
                if let albumArtist = metadata.albumArtist {
                    print("  Album Artist: \(albumArtist)")
                }
                if let track = metadata.track {
                    print("  Track:        \(track)")
                }
                if let year = metadata.year {
                    print("  Year:         \(year)")
                }
                if let art = metadata.artworkURL {
                    print("  Artwork URL:  \(art)")
                }
                if let mode = metadata.repeatMode {
                    print("  Repeat:       \(mode.rawValue)")
                }
                if let shuffle = metadata.shuffle {
                    print("  Shuffle:      \(shuffle)")
                }
                // Progress contains a snapshot timestamp — use currentPositionMs(at:)
                // with client.currentServerTimeMicroseconds() to interpolate live.
                if let progress = metadata.progress {
                    print("  Progress:     \(progress.trackProgressMs)ms / \(progress.trackDurationMs)ms  " +
                          "speed=\(progress.playbackSpeedX1000)/1000")
                }
                print("")

            // MARK: groupUpdated
            // Fired when the client joins a group or the group's playback state changes.
            // playbackState is optional because the server may omit it from the delta.
            case .groupUpdated(let info):
                print("--- Group Updated ---")
                print("  Group:    \(info.groupName)")
                let stateStr = info.playbackState.map { "\($0)" } ?? "(unchanged)"
                print("  Playback: \(stateStr)")
                print("")

            // MARK: streamStarted
            // Fired when the server begins streaming audio. Even though this client
            // has no player role (and will not receive or decode audio), the server
            // still notifies metadata clients so they can update stream-format UI.
            case .streamStarted(let format):
                print("--- Stream Started ---")
                print("  Codec:       \(format.codec.rawValue)")
                print("  Sample Rate: \(format.sampleRate) Hz")
                print("  Channels:    \(format.channels)")
                print("  Bit Depth:   \(format.bitDepth)-bit")
                print("")

            // MARK: streamEnded
            // Fired when the server stops the audio stream (e.g. playback stopped,
            // source exhausted). Metadata is not cleared — the last known track
            // stays in client.currentMetadata until a new track starts.
            case .streamEnded:
                print("--- Stream Ended ---\n")

            // MARK: disconnected
            // Fired when the connection drops (network loss) or when disconnect()
            // is called explicitly (SIGINT handler above). We `return` so the
            // function (and therefore the whole example) exits — the
            // `client.events` stream is intentionally kept alive by
            // SendspinClient across reconnects, so we can't rely on the stream
            // finishing to break out of this `for await`.
            case .disconnected(let reason):
                switch reason {
                case .connectionLost:
                    print("--- Disconnected (connection lost) ---")
                case .explicit(let goodbye):
                    print("--- Disconnected (\(goodbye.rawValue)) ---")
                }
                return

            default:
                // Events like .controllerStateUpdated, .artworkStreamStarted, etc.
                // are not relevant for a metadata-only client.
                break
            }
        }
    }
}
