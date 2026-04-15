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

A ``SendspinClient`` needs a unique ID, display name, and at least one role. Players also need a ``PlayerConfiguration`` declaring supported audio formats.

```swift
import SendspinKit

let client = SendspinClient(
    clientId: UUID().uuidString,
    name: "Kitchen Speaker",
    roles: [.playerV1, .metadataV1],
    playerConfig: PlayerConfiguration(
        bufferCapacity: 1_048_576,
        supportedFormats: [
            AudioFormatSpec(codec: .opus, channels: 2, sampleRate: 48000, bitDepth: 16),
            AudioFormatSpec(codec: .flac, channels: 2, sampleRate: 48000, bitDepth: 16),
            AudioFormatSpec(codec: .pcm, channels: 2, sampleRate: 48000, bitDepth: 16),
        ]
    )
)
```

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

Use ``ClientAdvertiser`` to publish your client on the network and let servers connect to you:

```swift
let advertiser = ClientAdvertiser(
    name: "Kitchen Speaker",
    port: SendspinDefaults.clientPort
)
try await advertiser.start()

for await connection in advertiser.connections {
    try await client.acceptConnection(connection)
    break
}
```

## Listen for events

``SendspinClient`` exposes an ``AsyncStream`` of ``ClientEvent`` values covering the full lifecycle:

```swift
for await event in client.events {
    switch event {
    case .serverConnected(let info):
        print("Connected to \(info.name)")
    case .metadataReceived(let metadata):
        print("Now playing: \(metadata.title ?? "Unknown")")
    case .streamStarted(let format):
        print("Streaming \(format.codec) at \(format.sampleRate)Hz")
    case .disconnected(let reason):
        print("Disconnected: \(reason)")
    default:
        break
    }
}
```

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
