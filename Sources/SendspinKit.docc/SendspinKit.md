# ``SendspinKit``

A Swift client library for the Sendspin Protocol — synchronized multi-room audio playback on Apple platforms.

## Overview

SendspinKit handles the full Sendspin protocol lifecycle: server discovery via mDNS/Bonjour, WebSocket transport, NTP-style clock synchronization, and timestamp-based audio scheduling with microsecond precision.

The library supports multiple client roles (player, controller, metadata, artwork, visualizer) and audio codecs (PCM, Opus, FLAC) including hi-res formats up to 192kHz/24-bit.

Built with Swift 6 strict concurrency — all public types are ``Sendable``, mutable state is actor-isolated, and events flow through ``AsyncStream``.

```swift
import SendspinKit

let client = SendspinClient(
    clientId: "my-device",
    name: "Living Room Speaker",
    roles: [.playerV1],
    playerConfig: PlayerConfiguration(
        bufferCapacity: 1_048_576,
        supportedFormats: [
            AudioFormatSpec(codec: .opus, channels: 2, sampleRate: 48000, bitDepth: 16)
        ]
    )
)

let discovery = ServerDiscovery()
try await discovery.startDiscovery()

for await servers in discovery.servers {
    if let server = servers.first {
        try await client.connect(to: server.url)
        break
    }
}
```

## Topics

### Essentials

- <doc:GettingStarted>
- ``SendspinClient``
- ``SendspinDefaults``

### Configuration

- ``PlayerConfiguration``
- ``ArtworkConfiguration``
- ``AudioFormatSpec``
- ``AudioCodec``
- ``VersionedRole``

### Discovery and Connection

- <doc:Discovery>
- ``ServerDiscovery``
- ``ClientAdvertiser``
- ``DiscoveredServer``
- ``ConnectionState``

### Events and State

- <doc:Events>
- ``ClientEvent``
- ``PlaybackState``
- ``TrackMetadata``
- ``PlaybackProgress``
- ``ControllerState``
- ``ServerInfo``
- ``GroupInfo``
- ``RepeatMode``

### Commands

- ``ControllerCommandType``
- ``DisconnectReason``
- ``GoodbyeReason``

### Audio

- <doc:AudioPipeline>

### Errors

- ``SendspinClientError``
- ``StreamingError``
- ``TerminatedError``
