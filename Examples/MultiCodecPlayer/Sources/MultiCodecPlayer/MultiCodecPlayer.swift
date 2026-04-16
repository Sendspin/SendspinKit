// ABOUTME: Demonstrates codec format negotiation with SendspinKit
// ABOUTME: Specifies preferred formats; server picks best match from the list

import ArgumentParser
import Foundation
import SendspinKit

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

// MARK: - Codec helpers

/// Opus on the wire is always 48 kHz / 16-bit (libopus decoder convention).
/// Named here so the negotiation logic below isn't peppered with magic numbers.
private enum OpusWireFormat {
    static let sampleRate: Int = 48_000
    static let bitDepth: Int = 16
}

private func parseCodecs(from string: String) -> [AudioCodec] {
    string.split(separator: ",")
        .compactMap { AudioCodec(rawValue: String($0).trimmingCharacters(in: .whitespaces)) }
}

private func codecDescription(_ codec: AudioCodec) -> String {
    switch codec {
    case .flac: "FLAC: lossless compression"
    case .opus: "Opus: lossy low-latency"
    case .pcm:  "PCM: uncompressed"
    }
}

private func bitrateKbps(format: AudioFormatSpec) -> Int {
    format.bitDepth * format.channels * format.sampleRate / 1_000
}

// MARK: - Command

@main
struct MultiCodecPlayer: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Demonstrates codec format negotiation — specify preferred codecs, server picks best match."
    )

    @Option(help: "WebSocket URL of the Sendspin server (e.g. ws://192.168.1.10:8927/sendspin)")
    var server: String?

    @Flag(help: "Auto-discover a server via mDNS")
    var discover: Bool = false

    @Option(help: "Discovery timeout in seconds")
    var timeout: Double = 5.0

    @Option(name: .customLong("prefer"), help: "Comma-separated codec preference order (flac,opus,pcm)")
    var prefer: String = "flac,opus,pcm"

    @Option(help: "Preferred sample rate in Hz")
    var sampleRate: Int = 48_000

    @Option(help: "Preferred bit depth (16, 24, or 32)")
    var bitDepth: Int = 16

    @Option(help: "Seconds to play before disconnecting (0 = indefinite)")
    var duration: Int = 30

    @MainActor
    func run() async throws {
        let url = try await resolveServerURL(server: server, discover: discover, timeout: timeout)

        // 1. Parse --prefer into [AudioCodec]
        let preferredCodecs = parseCodecs(from: prefer)
        guard !preferredCodecs.isEmpty else {
            throw ValidationError("--prefer must contain at least one valid codec (flac, opus, pcm)")
        }

        // 2. Build AudioFormatSpec array: each codec x mono x stereo at the requested rate/depth
        //    Order matters — server picks the first compatible format from this list.
        //    Opus is constrained to a single on-the-wire format (see `OpusWireFormat`),
        //    so it ignores `--sample-rate` / `--bit-depth` rather than failing validation.
        var formats: [AudioFormatSpec] = []
        for codec in preferredCodecs {
            for channels in [2, 1] {
                let effectiveSampleRate = (codec == .opus) ? OpusWireFormat.sampleRate : sampleRate
                let effectiveBitDepth = (codec == .opus) ? OpusWireFormat.bitDepth : bitDepth

                if let spec = try? AudioFormatSpec(
                    codec: codec,
                    channels: channels,
                    sampleRate: effectiveSampleRate,
                    bitDepth: effectiveBitDepth
                ) {
                    formats.append(spec)
                }
            }
        }

        guard !formats.isEmpty else {
            throw ValidationError("Could not build any valid AudioFormatSpec from the given parameters.")
        }

        print("Supported formats (preference order):")
        for (i, fmt) in formats.enumerated() {
            print("  [\(i + 1)] \(fmt.codec.rawValue) \(fmt.channels)ch \(fmt.sampleRate)Hz \(fmt.bitDepth)-bit")
        }

        // 3. Create PlayerConfiguration — 1 MB buffer
        let playerConfig = try PlayerConfiguration(
            bufferCapacity: 1_048_576,
            supportedFormats: formats
        )

        // 4. Create client with playerV1 role
        let client = try SendspinClient(
            clientId: "multicodec-example-\(UUID().uuidString.prefix(8))",
            name: "MultiCodecPlayer",
            roles: [.playerV1],
            playerConfig: playerConfig
        )

        // 5. If duration > 0, schedule disconnect after the deadline
        if duration > 0 {
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(duration))
                print("\nDuration limit reached (\(duration)s). Disconnecting...")
                await client.disconnect(reason: .shutdown)
            }
        }

        print("\nConnecting to \(url)...")
        try await client.connect(to: url)

        // 6. Monitor events — this loop exits when .disconnected arrives
        for await event in client.events {
            switch event {
            case let .serverConnected(info):
                print("[connected] \(info.name) (v\(info.version))")
                let roles = info.activeRoles.map(\.identifier).sorted().joined(separator: ", ")
                print("[roles] \(roles)")

            case let .streamStarted(format):
                printFormatInfo(label: "stream started", format: format, preferred: formats)

            case let .streamFormatChanged(format):
                // Mid-stream format switch — e.g. after requestPlayerFormat()
                printFormatInfo(label: "format changed", format: format, preferred: formats)

            case .streamEnded:
                print("[stream ended]")

            case let .metadataReceived(metadata):
                let artist = metadata.artist ?? "Unknown"
                let title = metadata.title ?? "Unknown"
                print("[now playing] \(artist) - \(title)")

            case let .groupUpdated(info):
                let state = info.playbackState?.rawValue ?? "unknown"
                print("[group] \(info.groupName.isEmpty ? info.groupId : info.groupName): \(state)")

            case let .disconnected(reason):
                print("[disconnected] \(reason)")
                return

            default:
                break
            }
        }
    }
}

// MARK: - Format display

private func printFormatInfo(label: String, format: AudioFormatSpec, preferred: [AudioFormatSpec]) {
    print("\n[\(label)]")
    print("  Codec:       \(format.codec.rawValue)")
    print("  Channels:    \(format.channels) (\(format.channels == 1 ? "mono" : "stereo"))")
    print("  Sample rate: \(format.sampleRate) Hz")
    print("  Bit depth:   \(format.bitDepth)-bit")
    print("  Description: \(codecDescription(format.codec))")
    print("  Bitrate:     ~\(bitrateKbps(format: format)) kbps (uncompressed equivalent)")

    // Show preference rank if the negotiated format is in our list
    if let rank = preferred.firstIndex(of: format) {
        print("  Preference:  #\(rank + 1) of \(preferred.count)")
    } else {
        print("  Preference:  (server chose a format outside our preference list)")
    }
}
