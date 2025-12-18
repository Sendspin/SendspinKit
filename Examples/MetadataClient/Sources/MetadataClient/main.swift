// ABOUTME: Demonstrates metadata-only client for SendspinKit
// ABOUTME: Connects as metadata role to display track information without playing audio

import Foundation
import SendspinKit
import ArgumentParser

@main
struct MetadataClient: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Monitor track metadata from a Sendspin server without playing audio",
        discussion: """
            This example demonstrates how to connect as a metadata-only client.
            Unlike a full player, this client only receives track information (title,
            artist, album, duration) without audio playback capabilities.

            This is useful for:
            • Display screens showing "now playing" information
            • Integration with external systems
            • Monitoring playback without consuming audio resources

            The client uses the metadata@v1 role and displays real-time updates
            as tracks change on the server.
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
        print("🎵 Sendspin Metadata Client")
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

            // selectedServer.url is already a URL
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

        // Create client with metadata-only role
        // Note: We only request metadata@v1 role, not player@v1
        // This tells the server we don't want audio chunks, only metadata
        let client = SendspinClient(
            clientId: UUID().uuidString,
            name: "MetadataClient",
            roles: [.metadataV1],  // Metadata-only role
            playerConfig: nil       // No player configuration needed
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
        print("Monitoring metadata (press Ctrl-C to exit)...")
        print("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
        print("")

        // Wait for event monitoring to complete (runs until interrupted)
        await eventTask.value
    }

    /// Monitor events from the client
    /// This function demonstrates the async event stream pattern used throughout SendspinKit
    @MainActor
    static func monitorEvents(client: SendspinClient, verbose: Bool) async {
        // Track current metadata to detect changes
        var currentTitle: String?
        var currentArtist: String?
        var currentAlbum: String?

        // Iterate over all events from the client
        // The 'for await' pattern is how we consume async streams in Swift
        // This loop will continue until the client disconnects or the task is cancelled
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
                // This tells us which playback group we're part of
                if verbose {
                    print("👥 Group: \(info.groupName)")
                    if let state = info.playbackState {
                        print("   Playback state: \(state)")
                    }
                    print("")
                }

            case let .metadataReceived(metadata):
                // New track metadata received - this is the main event we care about
                // The server sends this when the track changes

                // Check if this is actually a change (avoid duplicate prints)
                let titleChanged = metadata.title != currentTitle
                let artistChanged = metadata.artist != currentArtist
                let albumChanged = metadata.album != currentAlbum

                if titleChanged || artistChanged || albumChanged {
                    // Update our current state
                    currentTitle = metadata.title
                    currentArtist = metadata.artist
                    currentAlbum = metadata.album

                    // Display the new track information
                    print("🎵 Now Playing:")
                    print("   Title:  \(metadata.title ?? "Unknown")")
                    print("   Artist: \(metadata.artist ?? "Unknown")")
                    print("   Album:  \(metadata.album ?? "Unknown")")

                    // Additional metadata fields (optional)
                    if let albumArtist = metadata.albumArtist {
                        print("   Album Artist: \(albumArtist)")
                    }
                    if let track = metadata.track {
                        print("   Track Number: \(track)")
                    }
                    if let duration = metadata.duration {
                        // Duration is in seconds, format as MM:SS
                        let minutes = duration / 60
                        let seconds = duration % 60
                        print("   Duration: \(minutes):\(String(format: "%02d", seconds))")
                    }
                    if let year = metadata.year {
                        print("   Year: \(year)")
                    }
                    if let artworkUrl = metadata.artworkUrl, verbose {
                        print("   Artwork: \(artworkUrl)")
                    }
                    print("")
                }

            case let .streamStarted(format):
                // Stream started - metadata clients receive this but don't play audio
                // This tells us the audio format being streamed (even though we don't consume it)
                if verbose {
                    let formatStr = "\(format.codec.rawValue) \(format.sampleRate)Hz " +
                        "\(format.channels)ch \(format.bitDepth)bit"
                    print("🎶 Stream started: \(formatStr)")
                    print("   (Metadata-only client - not playing audio)")
                    print("")
                }

            case .streamEnded:
                // Stream ended
                if verbose {
                    print("⏹️  Stream ended")
                    print("")
                }

            case let .artworkReceived(channel: channel, data: data):
                // Artwork data received
                // Metadata clients can optionally receive artwork if they also request artwork@v1 role
                if verbose {
                    print("🖼️  Artwork received (channel \(channel)): \(data.count) bytes")
                    print("")
                }

            case let .visualizerData(data):
                // Visualizer data received
                if verbose {
                    print("📊 Visualizer data: \(data.count) bytes")
                    print("")
                }

            case let .error(message):
                // Error occurred
                print("❌ Error: \(message)")
                print("")
            }
        }

        // Event stream ended (client disconnected)
        if verbose {
            print("🔌 Disconnected from server")
        }
    }
}
