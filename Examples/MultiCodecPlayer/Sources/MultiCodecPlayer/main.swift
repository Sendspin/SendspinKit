// ABOUTME: Demonstrates codec format negotiation with SendspinKit
// ABOUTME: Shows how to specify preferred audio formats and observe what the server negotiates

import Foundation
import SendspinKit
import ArgumentParser

@main
struct MultiCodecPlayer: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Demonstrate codec format negotiation with SendspinKit",
        discussion: """
            This example shows how to configure preferred audio formats and observe the
            negotiation process. The client can specify multiple formats in priority order,
            and the server will select the best match from formats it supports.

            Format negotiation works by the client sending an array of AudioFormatSpec in
            priority order (most preferred first). The server selects the first format from
            the client's list that it can provide.

            Hi-res audio formats like 192kHz/24-bit FLAC are supported for audiophile playback.
            """
    )

    @Option(name: .long, help: "Server WebSocket URL (e.g., ws://localhost:8927)")
    var server: String?

    @Flag(name: .long, help: "Discover servers instead of connecting directly")
    var discover: Bool = false

    @Option(name: .shortAndLong, help: "Discovery timeout in seconds")
    var timeout: Int = 5

    @Option(name: .long, help: "Preferred codecs in priority order (comma-separated: opus,flac,pcm)")
    var prefer: String = "flac,opus,pcm"

    @Option(name: .long, help: "Preferred sample rate in Hz (e.g., 48000, 96000, 192000)")
    var sampleRate: Int = 48000

    @Option(name: .long, help: "Preferred bit depth (16, 24, 32)")
    var bitDepth: Int = 24

    @Option(name: .long, help: "Duration to play audio in seconds (0 = monitor indefinitely)")
    var duration: Int = 10

    @MainActor
    mutating func run() async throws {
        // Validate parameters
        guard bitDepth == 16 || bitDepth == 24 || bitDepth == 32 else {
            throw ValidationError("Bit depth must be 16, 24, or 32")
        }

        guard sampleRate > 0 && sampleRate <= 384_000 else {
            throw ValidationError("Sample rate must be between 1 and 384000 Hz")
        }

        guard duration >= 0 else {
            throw ValidationError("Duration must be non-negative")
        }

        // Parse preferred codecs
        let codecNames = prefer.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
        var codecs: [AudioCodec] = []

        for name in codecNames {
            guard let codec = AudioCodec(rawValue: name) else {
                throw ValidationError("Invalid codec '\(name)'. Valid codecs are: opus, flac, pcm")
            }
            codecs.append(codec)
        }

        if codecs.isEmpty {
            throw ValidationError("Must specify at least one codec")
        }

        // Build supported formats list in priority order
        print("🎯 Building format preferences...")
        print("")

        var supportedFormats: [AudioFormatSpec] = []
        for (index, codec) in codecs.enumerated() {
            let format = AudioFormatSpec(
                codec: codec,
                channels: 2, // stereo
                sampleRate: sampleRate,
                bitDepth: bitDepth
            )
            supportedFormats.append(format)

            let priority = index == 0 ? "HIGHEST" : "Priority \(index + 1)"
            print("  [\(priority)] \(codec.rawValue.uppercased()) - \(sampleRate)Hz, \(bitDepth)-bit, stereo")
        }
        print("")

        // Determine server URL
        var serverURL: String

        if discover {
            print("🔍 Discovering Sendspin servers...")
            let timeoutDuration = Duration.seconds(timeout)
            let servers = await SendspinClient.discoverServers(timeout: timeoutDuration)

            if servers.isEmpty {
                print("❌ No Sendspin servers found on the local network")
                print("")
                print("💡 Tips:")
                print("   • Make sure a Sendspin server is running")
                print("   • Try using --server ws://localhost:8927 for direct connection")
                throw ExitCode.failure
            }

            let selected = servers[0]
            print("✅ Found server: \(selected.name)")
            print("   URL: \(selected.url)")
            print("")
            serverURL = selected.url.absoluteString
        } else {
            guard let url = server else {
                throw ValidationError("Must specify --server <url> or use --discover")
            }
            serverURL = url
            print("🔗 Connecting to: \(serverURL)")
            print("")
        }

        // Create player configuration
        let config = PlayerConfiguration(
            bufferCapacity: 1024 * 1024, // 1MB buffer
            supportedFormats: supportedFormats
        )

        // Create client with player role
        guard let url = URL(string: serverURL) else {
            throw ValidationError("Invalid server URL: \(serverURL)")
        }

        let client = SendspinClient(
            clientId: UUID().uuidString,
            name: "MultiCodecPlayer",
            roles: [.playerV1],
            playerConfig: config
        )

        // Connect to server
        print("🔌 Connecting as player...")
        try await client.connect(to: url)
        print("✅ Connected!")
        print("")

        // Monitor events to see negotiated format
        var negotiatedFormat: AudioFormatSpec?

        print("👂 Monitoring stream events...")
        if duration > 0 {
            print("⏱️  Will play for \(duration) seconds")
        } else {
            print("⏱️  Monitoring indefinitely (Ctrl+C to stop)")
        }
        print("")

        // Create task to monitor events
        let eventTask = Task {
            for await event in client.events {
                switch event {
                case let .streamStarted(format):
                    negotiatedFormat = format

                    print("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
                    print("🎶 STREAM STARTED - Format Negotiation Result")
                    print("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
                    print("")

                    print("📋 What you requested (in priority order):")
                    for (index, requestedFormat) in supportedFormats.enumerated() {
                        let prefix = index == 0 ? "  1️⃣" : "  \(index + 1)️⃣"
                        let formatStr = "\(requestedFormat.codec.rawValue.uppercased()) - " +
                            "\(requestedFormat.sampleRate)Hz, \(requestedFormat.bitDepth)-bit, " +
                            "\(requestedFormat.channels)ch"
                        print("\(prefix) \(formatStr)")
                    }
                    print("")

                    print("✅ What the server selected:")
                    let formatStr = "\(format.codec.rawValue.uppercased()) - " +
                        "\(format.sampleRate)Hz, \(format.bitDepth)-bit, \(format.channels)ch"
                    print("   \(formatStr)")
                    print("")

                    // Check if we got our first choice
                    if format == supportedFormats[0] {
                        print("🎯 Server selected your FIRST CHOICE format!")
                    } else if supportedFormats.contains(format) {
                        if let matchIndex = supportedFormats.firstIndex(of: format) {
                            print("⚠️  Server selected your choice #\(matchIndex + 1)")
                            print("   This means the server couldn't provide your higher priority formats")
                        }
                    } else {
                        print("❌ Server selected a format NOT in your preference list")
                        print("   This might indicate a protocol mismatch or server limitation")
                    }
                    print("")

                    // Show codec characteristics
                    print("📊 Codec characteristics:")
                    switch format.codec {
                    case .opus:
                        print("   Opus: Low-latency, lossy compression, optimized for voice/music")
                        print("   Typical compression: 8:1 to 12:1")
                    case .flac:
                        print("   FLAC: Lossless compression, bit-perfect audio")
                        print("   Typical compression: 2:1 to 3:1")
                    case .pcm:
                        print("   PCM: Uncompressed raw audio, highest quality, largest bandwidth")
                        print("   No compression: Full bitrate")
                    }
                    print("")

                    // Calculate expected bitrate
                    let bitsPerSample = format.bitDepth * format.channels * format.sampleRate
                    let kbps = bitsPerSample / 1000
                    print("📈 Uncompressed bitrate: \(kbps) kbps")

                    if format.codec == .pcm {
                        print("   Network bandwidth required: \(kbps) kbps")
                    }
                    print("")

                    print("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
                    print("")

                case .streamEnded:
                    print("")
                    print("⏹️  Stream ended")

                case let .metadataReceived(metadata):
                    print("")
                    print("🎵 Metadata:")
                    print("   \(metadata.artist ?? "Unknown Artist") - \(metadata.title ?? "Unknown Title")")
                    if let album = metadata.album {
                        print("   Album: \(album)")
                    }

                default:
                    break
                }
            }
        }

        // Wait for the specified duration or indefinitely
        if duration > 0 {
            try await Task.sleep(for: .seconds(duration))
            print("")
            print("⏰ Duration elapsed, disconnecting...")
        } else {
            // Wait indefinitely (until Ctrl+C)
            try await Task.sleep(for: .seconds(Int.max))
        }

        // Clean up
        eventTask.cancel()
        await client.disconnect()

        // Final summary
        print("")
        print("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
        print("📊 SESSION SUMMARY")
        print("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")

        if let format = negotiatedFormat {
            print("Negotiated format: \(format.codec.rawValue.uppercased()) - \(format.sampleRate)Hz, \(format.bitDepth)-bit, \(format.channels)ch")
            print("Session duration: \(duration) second\(duration == 1 ? "" : "s")")
        } else {
            print("No stream was started during this session")
        }

        print("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
        print("")
        print("✨ Disconnected successfully!")
    }
}
