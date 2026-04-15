# SendspinKit

A Swift client library for the [Sendspin Protocol](https://github.com/Sendspin/spec) — enabling synchronized multi-room audio playback on Apple platforms.

## Features

- **Player Role** — Synchronized audio playback with microsecond-precision clock sync
- **Controller Role** — Play, pause, skip, volume, shuffle, repeat across device groups
- **Metadata Role** — Track info, artwork URLs, and playback progress
- **Artwork Role** — Album art delivery with format and resolution negotiation
- **Auto-discovery** — mDNS/Bonjour server discovery with continuous or one-shot modes
- **Multi-codec** — PCM, Opus, and FLAC support with seamless mid-stream format switching
- **Clock Sync** — Kalman filter time synchronization with drift tracking and adaptive forgetting
- **Hardware & Software Volume** — Perceptual gain curve with per-device or per-queue control

## Requirements

- iOS 17.0+ / macOS 14.0+ / tvOS 17.0+ / watchOS 10.0+
- Swift 6.0+

## Installation

### Swift Package Manager

```swift
dependencies: [
    .package(url: "https://github.com/Sendspin/SendspinKit.git", from: "1.0.0")
]
```

## Quick Start

```swift
import SendspinKit

// Create a player client
let client = try SendspinClient(
    clientId: "my-device",
    name: "Living Room Speaker",
    roles: [.playerV1],
    playerConfig: try PlayerConfiguration(
        bufferCapacity: 1_048_576,
        supportedFormats: [
            try AudioFormatSpec(codec: .pcm, channels: 2, sampleRate: 48_000, bitDepth: 16),
            try AudioFormatSpec(codec: .flac, channels: 2, sampleRate: 48_000, bitDepth: 16),
        ]
    )
)

// Discover and connect to the first server found
let servers = try await SendspinClient.discoverServers(timeout: .seconds(5))
if let server = servers.first {
    try await client.connect(to: server.url)
}

// React to events
for await event in client.events {
    switch event {
    case .streamStarted(let format):
        print("Playing \(format.codec) at \(format.sampleRate)Hz")
    case .metadataReceived(let metadata):
        print("Now playing: \(metadata.title ?? "Unknown")")
    case .disconnected(let reason):
        print("Disconnected: \(reason)")
    default:
        break
    }
}
```

### Controller + Metadata

```swift
let controller = try SendspinClient(
    clientId: "my-remote",
    name: "Kitchen Display",
    roles: [.controllerV1, .metadataV1]
)

try await controller.connect(to: serverURL)

// Control playback
try await controller.play()
try await controller.next()
try await controller.setGroupVolume(75)
try await controller.setShuffle(true)
```

### Continuous Discovery

```swift
let discovery = try await SendspinClient.discoverServers()
for await servers in discovery.servers {
    print("Found \(servers.count) server(s):")
    for server in servers {
        print("  \(server.name) at \(server.url)")
    }
}
```

## Codec Support

- **PCM** — Uncompressed audio up to 192kHz/32-bit (zero-copy passthrough)
- **Opus** — Low-latency lossy compression (8-48kHz, optimized for real-time)
- **FLAC** — Lossless compression with hi-res support (up to 192kHz/24-bit)

All codecs output normalized int32 PCM for consistent pipeline processing.

## Audio Synchronization

SendspinKit uses a Kalman filter for clock synchronization and timestamp-based audio scheduling:

- **Clock Sync** — Full 2D covariance Kalman filter with adaptive forgetting, drift SNR gating, and RTT floor
- **AudioScheduler** — Priority queue of audio chunks sorted by playback time
- **Playback Window** — Configurable tolerance for network jitter (default +/-50ms)
- **Sync Correction** — Frame-level drop/insert to maintain alignment without audible glitches

## Documentation

API documentation is available via DocC. Build it locally with:

```bash
swift package generate-documentation
```

## License

Apache 2.0
