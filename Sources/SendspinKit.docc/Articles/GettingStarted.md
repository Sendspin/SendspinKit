# Getting Started

Connect to a Sendspin server and start playing audio in under 20 lines of code.

## Overview

SendspinKit manages the full protocol lifecycle automatically. You configure a client with your desired roles and formats, discover or accept a server connection, and the library handles clock synchronization, codec negotiation, and audio scheduling.

## Install the package

Add SendspinKit to your `Package.swift` or Xcode project:

```swift
dependencies: [
    .package(url: "https://github.com/sendspin/SendspinKit.git", from: "0.1.0")
]
```

## Create a client

A ``SendspinClient`` needs a ``SendspinDevice``, display name, at least one role, and an explicit ``AccessPolicy``. Open the device from app-owned storage — ``KeychainSendspinDeviceStorage`` keeps the identity, pairing secret, and per-server pairing records across launches — or use ``SendspinDevice/ephemeral()`` for a deliberately non-persistent demo or test device. Players also need a ``PlayerConfiguration`` declaring supported audio formats. Artwork and visualizer roles likewise require their role configuration.

```swift
import SendspinKit

// App-defined namespace; the device snapshot is created on first open and reloaded afterwards.
let device = try await SendspinDevice.open(
    storage: try KeychainSendspinDeviceStorage(service: "com.example.app", account: "sendspin-device")
)

let client = try SendspinClient(
    device: device,
    name: "Kitchen Speaker",
    roles: [.playerV1, .metadataV1],
    playerConfig: try PlayerConfiguration(
        bufferCapacity: 1_048_576,
        supportedFormats: [
            try AudioFormatSpec(codec: .opus, channels: 2, sampleRate: 48000, bitDepth: 16),
            try AudioFormatSpec(codec: .flac, channels: 2, sampleRate: 48000, bitDepth: 16),
            try AudioFormatSpec(codec: .pcm, channels: 2, sampleRate: 48000, bitDepth: 16),
        ],
        requiredLeadTimeMs: 100,
        minBufferMs: 500
    ),
    access: .allowUnpaired // convenient for first-run demos; use .pairedOnly in production
)
```

For artwork, provide an ``ArtworkConfiguration`` with one to four ``ArtworkChannel`` values;
use ``ArtworkChannelPreference`` and ``SendspinClient/setArtworkChannelPreference(channel:preference:)``
to change a channel while connected. For visualizer data, provide a ``VisualizerConfiguration``;
include ``SpectrumConfiguration`` whenever the requested types contain ``VisualizerType/spectrum``.
These role configurations seed the initial `client/state` snapshot; dynamic preference changes use the
corresponding state-preference APIs.

A visualizer consumer owns one bounded subscription. Consume frames FIFO, use the monotonic
``PresentationClock`` to await each future ``VisualizerFrame/presentationTime``, then check
``VisualizerFrame/isValid`` before handing the due value to the UI. `isValid` checks stream generation
only, so a due frame can remain valid; `eligibilityForScheduling(at:)` is the pre-deadline gate.
Never convert these instants through wall-clock time or retain an unbounded app queue.

```swift
let frames = try client.acquireVisualizerFrames()
let consumer = Task {
    var iterator = frames.makeAsyncIterator()
    let clock = PresentationClock()
    while let frame = await iterator.next() {
        if frame.eligibilityForScheduling(at: clock.now) {
            try await clock.sleep(until: frame.presentationTime)
        }
        guard frame.isValid else { continue }
        // Replace the latest due value for this type in a bounded UI mailbox.
        submitDueFrame(frame)
    }
}

// On shutdown: consumer.cancel(); frames.cancel(); await client.close()
```

A display-link submission is not a guarantee of the next screen refresh or screen-photon time; an
app must not claim exact refresh synchronization without an independently measured clock mapping.
See the runnable ``VisualizerClient`` example for a SwiftUI/AppKit implementation.

## Leave a group

Any client role can leave its current server group:

```swift
try await client.leaveGroup()
```

This sends `client/leave` with an empty payload. The server places the client in a stopped solo group;
SendspinKit does not invent or clear local group state, and returning to the previous group requires an
explicit server-directed group change. For non-interruptible local playback, use
``SendspinClient/enterExternalSource()`` and ``SendspinClient/exitExternalSource()``. Exiting an external
source makes the client available again but does not automatically rejoin its previous group.

## Connect to a server

There are two connection patterns:

### Client-initiated (discover servers)

Use ``ServerDiscovery`` to find Sendspin servers on the local network via mDNS:

```swift
let discovery = ServerDiscovery()
try await discovery.startDiscovery()

for await servers in discovery.servers {
    if let server = servers.first {
        try await client.connect(to: server.url)
        break
    }
}
```

### Server-initiated (advertise and accept)

Let the client publish its name and manage incoming connections:

```swift
try await client.startAdvertising(port: SendspinDefaults.clientPort)
```

This returns when the listener is ready. `client.listenerState` reports the listener lifecycle;
`client.connectionState` reports the admitted session. `client.stopAdvertising()` stops new
candidates without disconnecting admitted sessions. `client.close()` permanently stops both.
Do not advertise while using an outgoing connection. See <doc:Discovery> for lifecycle details.

## Listen for events

``SendspinClient`` exposes an ``AsyncStream`` of ``ClientEvent`` values covering the full lifecycle.
Handle the cases your app renders; see <doc:Events> for the complete list.

```swift
for await event in client.events() {
    if case let .serverConnected(info) = event {
        print("Connected to \(info.name)")
    } else if case let .metadataReceived(metadata) = event {
        print("Now playing: \(metadata.title ?? "Unknown")")
    } else if case let .streamStarted(format) = event {
        print("Streaming \(format.codec) at \(format.sampleRate)Hz")
    } else if case let .disconnected(reason) = event {
        print("Disconnected: \(reason)")
    }
}
```

## Handle protocol API constraints

- `SendspinClientError.connectionRefused(ServerErrorReason)` carries an unauthenticated setup refusal reason for diagnostics only.
- `PlayerConfiguration` requires FLAC or PCM and throws `ConfigurationError.missingLosslessFormat` for an Opus-only catalog.
- `requireCurrentOutput` throws `OutputFormatError.noMatchingLosslessFormat` if output filtering removes every FLAC and PCM format.
- `setVisualizerPreference(_:)` publishes a new visualizer request, including empty `types` to request no visualizer data.
- Controller commands throw `controllerStateUnavailable` before the first state or `controllerCommandUnsupported` when absent from the latest `supported_commands`.

## Pair with a code

Code-based pairing is coordinated by the host app. Declare the presentation your device can actually provide via the client's `pairing` argument (``PairingPresentation``): `.display`, `.digitDisplay`, `.speaker`, `.displayAndSpeaker`, or `.staticCode` — the default `.tokenOnly` presents no dynamic code. Then start consuming ``SendspinClient/events`` and retain the complete ``PairingAttemptSnapshot`` that drives the operator UI:

```swift
for await event in client.events() {
    if case let .pairingCodeChanged(snapshot) = event {
        if let code = snapshot.code {
            print("Pairing \(code.format.rawValue): \(code.payload)")
        }
    } else if case let .pairingAttemptEnded(snapshot) = event {
        print("Pairing attempt \(snapshot.id.rawValue) ended: \(snapshot.phase)")
    } else if case let .paired(snapshot) = event {
        print("Paired with \(snapshot.peer.name); trust: \(snapshot.peer.trustLevel)")
    }
}
```

Call ``SendspinClient/openPairingWindow(for:)`` with the ID captured by the rendered snapshot when
the app receives its physical-gesture or other operator-confirmation signal. It returns after
recording operator consent and resetting the emitted-round budget, including an already-open window;
it does not wait for the attempt. To cancel,
call ``SendspinClient/cancelPairing(attemptID:)`` with that same captured ID. A stale ID throws
``SendspinClientError/stalePairingAttempt(_:)`` and never retargets a newer attempt. The observable
``SendspinClient/currentPairing`` retains the latest genuine terminal snapshot until a new attempt
starts. A server activation that supersedes or abandons an attempt instead emits
`ClientEvent.pairingAttemptSuperseded` with its ID and clears that attempt's projection.
``SendspinClient/pairingWindow`` is connection-scoped and survives timed-out, cancelled, and
superseded attempts. It becomes `nil` only when the window expires or closes; pass its published
`attemptID` to ``SendspinClient/cancelPairing(attemptID:)`` to close a surviving window. Its
`expiresAt` is not a trust assertion. The peer ID is unverified while
``PairingPeer/trustLevel`` is `.none`; the authorization window is not proof of server trust. Dynamic
codes are six contiguous digits or a complete version-one `SP:1` token. If
the presentation includes a speaker, the host app speaks single digits using its own bundled
recordings or synthesizer; the server supplies no audio. Use ``PairingCodeEmission/languages`` as
the language priority list for RFC 4647 Lookup matching against the languages the app supports,
falling back to the app's default. Present dynamic digits in two groups of three, with a short gap
between digits and a longer gap between groups; separators are presentation-only. Static pairing instead requires the
host to provision a device-unique eight-digit ASCII decimal code when opening the device —
``SendspinDevice/open(storage:staticCode:capacity:)`` — and to declare `pairing: .staticCode` when
creating the client; the library never supplies a fixed default or emits that secret. Declare
exactly one presentation per client. Dynamic pairing binds device presence, while a leaked static
code is exposed to man-in-the-middle pairing.

The device's setup token is exported only through ``SendspinDevice/makePairingToken()``. Treat the
returned ``PairingToken`` as a secret: present it from an explicit operator-facing setup flow, and
never log or transmit it during normal startup.

## Observe state in SwiftUI

``SendspinClient`` is `@Observable`, so its published properties work directly with SwiftUI:

```swift
struct PlayerView: View {
    let client: SendspinClient

    var body: some View {
        VStack {
            Text(client.connectionState == .connected ? "Connected" : "Disconnected")
            if let format = client.currentStreamFormat {
                Text("\(format.codec.rawValue) \(format.sampleRate)Hz")
            }
        }
    }
}
```

## Disconnect

```swift
await client.disconnect(reason: .clientShutdown)
```
