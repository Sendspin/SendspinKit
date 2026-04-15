# Events and Observable State

React to server events and bind client state to your UI.

## Overview

SendspinKit provides two complementary ways to observe state: an event stream for discrete occurrences and observable properties for continuous UI binding.

## Event stream

``SendspinClient/events`` is an `AsyncStream<ClientEvent>` that emits every significant protocol event:

| Event | When |
|-------|------|
| ``ClientEvent/serverConnected(_:)`` | Handshake complete, roles activated |
| ``ClientEvent/streamStarted(_:)`` | Audio stream begins with format info |
| ``ClientEvent/streamFormatChanged(_:)`` | Codec or sample rate changed mid-stream |
| ``ClientEvent/streamEnded`` | Server stopped the audio stream |
| ``ClientEvent/streamCleared`` | Buffers flushed (e.g., seek operation) |
| ``ClientEvent/metadataReceived(_:)`` | Track metadata updated |
| ``ClientEvent/groupUpdated(_:)`` | Group membership or playback state changed |
| ``ClientEvent/controllerStateUpdated(_:)`` | Supported commands, group volume/mute changed |
| ``ClientEvent/artworkReceived(channel:data:)`` | Album art data arrived |
| ``ClientEvent/disconnected(reason:)`` | Connection ended |

The stream is consumed exactly once. Start iterating before connecting:

```swift
Task {
    for await event in client.events {
        handleEvent(event)
    }
}
try await client.connect(to: serverURL)
```

## Observable properties

``SendspinClient`` is `@Observable`, making these properties directly usable in SwiftUI views without wrappers:

- ``SendspinClient/connectionState`` — current connection lifecycle state
- ``SendspinClient/currentStreamFormat`` — active audio format, or `nil`
- ``SendspinClient/currentVolume`` — player volume (0-100)
- ``SendspinClient/currentMuted`` — mute state
- ``SendspinClient/staticDelayMs`` — static playback delay in milliseconds

These properties update on the main actor and trigger SwiftUI view updates automatically.
