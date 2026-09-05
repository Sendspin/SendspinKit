# SendspinKit

A Swift client library for the [Sendspin Protocol](https://github.com/Sendspin/spec) — enabling synchronized multi-room audio playback on Apple platforms.

## Features

- **Player Role** — Synchronized audio playback with microsecond-precision clock sync
- **Controller Role** — Play, pause, skip, volume, shuffle, repeat across device groups
- **Metadata Role** — Track info, artwork URLs, and playback progress
- **Artwork Role** — Album art delivery with format and resolution negotiation
- **Visualizer Role** — Configurable beat, loudness, peak, and spectrum data
- **Color Role** — Synchronized album and audio-derived color themes
- **Auto-discovery** — mDNS/Bonjour server discovery with continuous or one-shot modes
- **Multi-codec** — PCM, Opus, and FLAC support with seamless mid-stream format switching
- **Clock Sync** — Kalman filter time synchronization with drift tracking and adaptive forgetting
- **Hardware & Software Volume** — Perceptual gain curve with per-device or per-queue control

## Requirements

- iOS 17.0+ / macOS 14.0+ / tvOS 17.0+ / watchOS 10.0+
- Swift 6.2+

## Installation

### Swift Package Manager

```swift
dependencies: [
    .package(url: "https://github.com/Sendspin/SendspinKit.git", from: "1.0.0")
]
```

## Quick Start

A `SendspinIdentity` is the device's long-lived cryptographic identity. The host app owns its
secret-key persistence: load `secretKeyBytes` from the Keychain (or another protected store) on
launch, and save the bytes from a newly generated identity before connecting. Rotating the secret
changes the device's `clientId`.

Pairing is also host-owned. Pass a `PairingConfiguration` with an app-backed
`PairingRecordStore` when pairing should survive process restarts. The default in-memory store is
useful for tests and demonstrations, but is not persistent. Treat the pairing PSK and the resulting
`PairingToken.string` as secrets; display or encode the token as a QR code only through a trusted
setup flow.

```swift
import SendspinKit

// Create a player client
let identity = SendspinIdentity.generate()
let pairing = PairingConfiguration() // Pass an app-backed PairingRecordStore in production.
let token = PairingToken(clientKey: identity.publicKeyBytes, pairingPsk: pairing.pairingPsk)
print("Pairing token: \(token.string)") // display or encode as a QR code

let client = try SendspinClient(
    identity: identity,
    name: "Living Room Speaker",
    roles: [.playerV1],
    playerConfig: try PlayerConfiguration(
        bufferCapacity: 1_048_576,
        supportedFormats: [
            try AudioFormatSpec(codec: .pcm, channels: 2, sampleRate: 48_000, bitDepth: 16),
            try AudioFormatSpec(codec: .flac, channels: 2, sampleRate: 48_000, bitDepth: 16),
        ],
        requiredLeadTimeMs: 100,
        minBufferMs: 500
    ),
    unpairedAccessEnabled: false,
    pairing: pairing
)

// Discover and connect to the first server found
let servers = try await SendspinClient.discoverServers(timeout: .seconds(5))
if let server = servers.first {
    try await client.connect(to: server.url)
}

// React to events
for await event in client.events() {
    switch event {
    case let .serverConnected(info):
        print("Connected to \(info.name); trust: \(info.trustLevel)")
    case let .paired(serverId):
        print("Paired with \(serverId)")
    case let .streamStarted(format):
        print("Playing \(format.codec) at \(format.sampleRate)Hz")
    case let .metadataReceived(metadata):
        print("Now playing: \(metadata.title ?? "Unknown")")
    case .audioOutputChanged, .outputFormatStatusChanged, .streamingFailed,
         .streamFormatChanged, .streamEnded, .streamCleared, .groupUpdated,
         .controllerStateUpdated, .colorStateUpdated, .colorStateCleared,
         .artworkStreamStarted, .outputDelayChanged, .lastPlayedServerChanged:
        break
    case let .disconnected(reason):
        print("Disconnected: \(reason)")
    }
}
```

`ServerInfo.trustLevel` reports whether the active session is backed by a pairing record
(`.user`) or is unpaired (`.none`). Set `unpairedAccessEnabled` to `false` when every server must
be paired. Enabling unpaired access deliberately permits unauthenticated server access, so an
on-path attacker can impersonate a server.

Dynamic player, artwork, and visualizer preferences are sent in `client/state`. Use
`setPlayerFormatPreference(_:)` or `setPlayerFormatPreference(codec:channels:sampleRate:bitDepth:)`
to select a supported audio format, and `setArtworkChannelPreference(channel:preference:)` with
`ArtworkChannelPreference.set(source:format:width:height:)` or `.disable` to update an artwork
channel. These preferences can be changed while connected and apply to the active or next stream.

## Pairing codes

Pairing-code flows are app-facing setup hooks. Enable a method in `PairingConfiguration`, then
listen to the existing `SendspinClient.events()` stream for
`ClientEvent.pairingCodeChanged(_:)`:

- Dynamic pairing emits a `PairingCodeEmission` with `format == .digits` and a contiguous six-digit
  `payload`, or with `format == .qrCode` and a complete version-one `SP:1` `payload`. Display or
  speak the value from the app; presentation grouping and QR image generation remain app
  responsibilities. When the server advertises the optional speaker capability, a digits emission
  also carries a validated `digitAudioPack`; the host app is responsible for decoding and playing
  those ten clips. A `nil` emission clears any displayed code.
- Call `try await client.openPairingWindow()` from the app's physical-gesture or equivalent
  operator-confirmation hook. The call records or consumes the connection-owned window intent and
  returns without waiting for pairing to finish. Call `try await client.cancelPairingAttempt()` to
  cancel an in-progress attempt or close the local window.
- Listen for `ClientEvent.pairingAttemptEnded(_:)` to distinguish reasons such as
  `.pairingCodeMismatch`, `.userCancelled`, `.attemptTimeout`, and `.methodNotSupported`.

Static pairing uses `PairingConfiguration(staticPairingCode:staticPairingCodeEnabled:)`. The host
must provision and persist a device-unique eight-digit ASCII decimal code; never ship a fixed
shared default. Hosts rotate the code through their local pairing configuration; the secret is
never exposed in client events. Static codes are not emitted as `pairingCodeChanged` events.

Dynamic pairing binds the code to the physical device-presence flow, so a relay cannot reuse a code
across different Noise handshakes. Static pairing authenticates the code but does not provide that
presence binding: if the static code leaks, an on-path attacker can use it to perform a
man-in-the-middle pairing flow.

### Controller + Metadata

```swift
let controller = try SendspinClient(
    identity: SendspinIdentity.generate(),
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

### Color Display

```swift
import SendspinKit
import SwiftUI

extension Color {
    init(_ rgb: RGBColor) {
        self.init(
            .sRGB,
            red: Double(rgb.red) / 255,
            green: Double(rgb.green) / 255,
            blue: Double(rgb.blue) / 255,
            opacity: 1
        )
    }
}

let colorDisplay = try SendspinClient(
    identity: SendspinIdentity.generate(),
    name: "Kitchen Display",
    roles: [.colorV1]
)

struct NowPlayingView: View {
    let client: SendspinClient

    var body: some View {
        PlayerControls()
            .background(client.currentColorState?.backgroundDark.map(Color.init) ?? .black)
            .foregroundStyle(client.currentColorState?.onDark.map(Color.init) ?? .white)
    }
}
```

`currentColorState` is observable and contains the latest accumulated theme. Each state includes
`serverTimestamp` and, once clock synchronization is ready, `localDisplayTime` for consumers that
schedule color changes alongside audio, artwork, or visualizer updates.

### Visualizer Configuration

Configure the visualizer role when creating the client. The requested types, maximum update rate,
and optional spectrum parameters are published in `client/state`; visualizer bytes are delivered
through `client.visualizerData`.

```swift
let visualizer = try SendspinClient(
    identity: SendspinIdentity.generate(),
    name: "Kitchen Display",
    roles: [.visualizerV1],
    visualizerConfig: try VisualizerConfiguration(
        types: [.loudness, .spectrum],
        rateMax: 30,
        spectrum: SpectrumConfiguration(nDispBins: 32, scale: .log, fMin: 60, fMax: 16_000)
    )
)
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
