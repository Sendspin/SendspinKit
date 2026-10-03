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

A `SendspinDevice` holds the enduring protocol state: the long-lived cryptographic identity, the
pairing secret, and per-server pairing records. The host app picks the storage backend and opens the
device before creating a client — `KeychainSendspinDeviceStorage` for production, or
`SendspinDevice.ephemeral()` for deliberately non-persistent demos and tests. Treat the pairing PSK
and the token from `device.makePairingToken()` as secrets; display or encode the token as a QR code
only through a trusted setup flow.

Apps with an existing secure store can implement `SendspinDeviceStorage` instead. The backend loads
and atomically replaces one opaque, secret-bearing snapshot, and its required `create(_:)` operation
must atomically create only when absent: return `false` without changing an existing snapshot.
Storage failures must throw, not masquerade as a missing device. Optional deletion supports explicit
destructive reset; the library chooses no filesystem location or app namespace.

Keep one live `SendspinDevice` per stored device, including across concurrent opens in the same
process, and one live client per device. Close the client before sequential reuse. Atomic creation
prevents identity overwrite during initialization; it does not synchronize multiple loaded devices
or support cross-process writers. Custom-backend ownership is the app's responsibility.

Every client states its access policy explicitly: `access: .pairedOnly` requires pairing before
normal roles activate, while `access: .allowUnpaired` permits roles on an unpaired server.

```swift
import SendspinKit

// Open the enduring device state from app-owned Keychain storage (created on first launch).
let device = try await SendspinDevice.open(
    storage: try KeychainSendspinDeviceStorage(service: "com.example.app", account: "sendspin-device")
)

// Export the setup token only for an intentional operator pairing flow.
let token = device.makePairingToken()
print("Pairing token: \(token.string)") // display or encode as a QR code

let client = try SendspinClient(
    device: device,
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
    access: .pairedOnly
)

// Discover and connect to the first server found
let servers = try await SendspinClient.discoverServers(timeout: .seconds(5))
if let server = servers.first {
    try await client.connect(to: server.url)
}

// React to the events this app cares about; ClientEvent has a case per protocol transition.
for await event in client.events() {
    if case let .serverConnected(info) = event {
        print("Connected to \(info.name); trust: \(info.trustLevel)")
    } else if case let .paired(snapshot) = event {
        print("Paired with \(snapshot.peer.id)")
    } else if case let .streamStarted(format) = event {
        print("Playing \(format.codec) at \(format.sampleRate)Hz")
    } else if case let .metadataReceived(metadata) = event {
        print("Now playing: \(metadata.title ?? "Unknown")")
    } else if case let .disconnected(reason) = event {
        print("Disconnected: \(reason)")
    }
}
```

`ServerInfo.trustLevel` reports whether the active session is backed by a pairing record
(`.user`) or is unpaired (`.none`). Pass `access: .pairedOnly` when every server must be paired.
`.allowUnpaired` deliberately permits unauthenticated server access, so an on-path attacker can
impersonate a server.

Dynamic player, artwork, and visualizer preferences are sent in `client/state`. Use
`setPlayerFormatPreference(_:)` or `setPlayerFormatPreference(codec:channels:sampleRate:bitDepth:)`
to select a supported audio format, and `setArtworkChannelPreference(channel:preference:)` with
`ArtworkChannelPreference.set(source:format:width:height:)` or `.disable` to update an artwork
channel. These preferences can be changed while connected and apply to the active or next stream.

### API behavior

- `SendspinClientError.connectionRefused(ServerErrorReason)` reports an unauthenticated setup refusal for diagnostics, not proof of server identity.
- `PlayerConfiguration` throws `ConfigurationError.missingLosslessFormat` unless its catalog includes FLAC or PCM.
- `requireCurrentOutput` throws `OutputFormatError.noMatchingLosslessFormat` when the output-filtered catalog has no FLAC or PCM format.
- `setVisualizerPreference(_:)` publishes visualizer preferences, and empty `types` disables requested visualizer data.
- Controller calls throw `controllerStateUnavailable` before the first controller state or `controllerCommandUnsupported` when its latest `supported_commands` excludes the command.
- Parameterless `PairingPresentation.speaker` and `.displayAndSpeaker` require host-provided speech, with `PairingCodeEmission.languages` supplying the language priority list.
- `openPairingWindow(for:)` is the operator gesture that resets the device-wide emitted-round budget, including while a window is open.
- `ClientEvent.pairingAttemptSuperseded` clears the superseded attempt's UI without reporting an operator abort.
- `cancelPairing(attemptID:)` also accepts `pairingWindow.attemptID` to close authorization after its attempt ends.

### Group membership and external sources

A client can leave its current group without requiring the controller role:

```swift
try await client.leaveGroup()
```

This sends `client/leave` with an empty payload. The server stops playback for this client and
places it in a solo group; the client does not invent or clear local group state, and returning to
the previous group requires an explicit server-directed group change. For non-interruptible local
playback, use `enterExternalSource()` and `exitExternalSource()` instead. Exiting an external source
makes the client available again but does not automatically rejoin its previous group.

## Pairing codes

Pairing-code flows are app-facing setup hooks. Declare the code presentation your device supports
with the client's `pairing: PairingPresentation` parameter, then
listen to `SendspinClient.events()` for `ClientEvent.pairingCodeChanged(_:)`,
`ClientEvent.pairingAttemptEnded(_:)`, and `ClientEvent.paired(_:)`. Each event carries a
`PairingAttemptSnapshot`; keep its `id` with the UI state that displayed its code.

- Dynamic pairing emits a `PairingCodeEmission` with `format == .digits` and a contiguous six-digit
  `payload`, or with `format == .qrCode` and a complete version-one `SP:1` `payload`. Display or
  speak the value from the app; presentation grouping and QR image generation remain app
  responsibilities. A `nil` `code` clears any displayed code.
- Call `try await client.openPairingWindow(for: snapshot.id)` from the app's physical-gesture or
  equivalent operator-confirmation hook. It records operator consent, resets the emitted-round budget,
  and returns without waiting for pairing to finish.
- Cancel only the attempt represented by the ID captured with the rendered snapshot:

  ```swift
  // `renderedPairing` is the immutable snapshot captured by the UI row/button.
  let displayedAttemptID = renderedPairing?.id
  if let displayedAttemptID {
      do {
          try await client.cancelPairing(attemptID: displayedAttemptID)
      } catch SendspinClientError.stalePairingAttempt {
          // The displayed attempt ended; do not retarget a newer attempt.
      }
  }
  ```

  `PairingAttemptID` is opaque. A retry retains its ID; a later activation receives a new one.
  `client.currentPairing` retains the latest terminal snapshot until another attempt starts.
  `client.pairingWindow` is the observable authorization window for that attempt and becomes `nil`
  when it expires or closes; its `expiresAt` is UI state, not a trust assertion.
  `snapshot.peer.id` is unverified while `snapshot.peer.trustLevel == .none`; only successful
  pairing establishes `.user` trust. The authorization window is operator consent, not server trust.
  Handle terminal `snapshot.phase` values such as
  `.ended(.pairingCodeMismatch)`, `.ended(.userCancelled)`, `.ended(.attemptTimeout)`, and
  `.ended(.methodNotSupported)` as outcomes rather than assuming cancellation succeeded.

Static pairing uses `pairing: .staticCode` with an eight-digit code provisioned on the device via
`SendspinDevice.open(storage:staticCode:)`. The host must provision and persist a device-unique
ASCII decimal code; never ship a fixed shared default. The secret is never exposed in client
events. Static codes are not emitted as `pairingCodeChanged` events.

Dynamic pairing binds the code to the physical device-presence flow, so a relay cannot reuse a code
across different Noise handshakes. Static pairing authenticates the code but does not provide that
presence binding: if the static code leaks, an on-path attacker can use it to perform a
man-in-the-middle pairing flow.

### Controller + Metadata

```swift
let controller = try SendspinClient(
    device: SendspinDevice.ephemeral(), // demo device; see Quick Start for Keychain-backed storage
    name: "Kitchen Display",
    roles: [.controllerV1, .metadataV1],
    access: .allowUnpaired
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
    device: SendspinDevice.ephemeral(), // demo device; see Quick Start for Keychain-backed storage
    name: "Kitchen Display",
    roles: [.colorV1],
    access: .allowUnpaired
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
and optional spectrum parameters are published in `client/state`; the server's negotiated types,
rate, conditional `tracks_downbeats`, and spectrum parameters are exposed by the
`.visualizerStreamStarted` event and `currentVisualizerStreamConfiguration`. Acquire the single
bounded data-plane consumer with `try client.acquireVisualizerFrames()`. Each `VisualizerFrame`
contains its type, raw payload, typed `presentationTime`, and the negotiated configuration that
validated it. The subscription drops stale frames and invalidates queued frames when a stream or
session ends; it never creates an unbounded producer queue.

Use `PresentationClock` and `PresentationInstant` for scheduling. A frame is eligible only while
`frame.eligibilityForScheduling(at: clock.now)` is true; after sleeping until its presentation
instant, capture a fresh instant and call `frame.isValid` immediately before submitting it to the
view model or display tick. `isValid` checks stream generation only, so a due frame can remain valid;
its deadline is a scheduling decision, not a lifetime check. Do not convert presentation instants
through wall clock time or draw a frame early. See `Examples/VisualizerClient` for a bounded SwiftUI
consumer; a display-link submission is not a guarantee about screen-photon timing.

```swift
let visualizer = try SendspinClient(
    device: SendspinDevice.ephemeral(), // demo device; see Quick Start for Keychain-backed storage
    name: "Kitchen Display",
    roles: [.visualizerV1],
    visualizerConfig: try VisualizerConfiguration(
        types: [.loudness, .spectrum],
        rateMax: 30,
        spectrum: SpectrumConfiguration(nDispBins: 32, scale: .log, fMin: 60, fMax: 16_000)
    ),
    access: .allowUnpaired
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

A successful command API call means that SendspinKit accepted and sent the encrypted command. It is
not a server acknowledgement and is not evidence that application audio has started, completed, or
become audible. Treat the subsequent state/event stream and audio output telemetry as separate
signals.

`outputDelayMs` models physical downstream delay after the client submits audio to its output path.
When the value changes, pending audio is retimed for the new delay and already submitted audio cannot
be rewritten. The command/event transition therefore does not create instantaneous acoustic
convergence: the new timing takes effect as the retimed pipeline reaches the downstream device.
Keep this distinction when measuring synchronization or presenting completion UI.

## Documentation

API documentation is available via DocC. Build it locally with:

```bash
swift package generate-documentation
```

## License

Apache 2.0
