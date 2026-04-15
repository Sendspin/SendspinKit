# Discovery and Connection

Find Sendspin servers on the local network or let servers find you.

## Overview

The Sendspin protocol supports two connection patterns. In **client-initiated** mode, the client discovers servers via mDNS and opens a WebSocket connection. In **server-initiated** mode, the client advertises itself and accepts incoming connections from servers.

Both patterns use Bonjour/mDNS service types defined in ``SendspinDefaults``.

## Client-initiated discovery

``ServerDiscovery`` uses the Network framework to browse for `_sendspin-server._tcp` services:

```swift
let discovery = ServerDiscovery()
try await discovery.startDiscovery()

// servers is an AsyncStream that emits the current set of discovered servers
// whenever a server appears or disappears
for await servers in discovery.servers {
    for server in servers {
        print("\(server.name) at \(server.url)")
    }
}
```

Each ``DiscoveredServer`` provides a resolved URL ready for ``SendspinClient/connect(to:)``.

When you're done discovering, stop the browser:

```swift
await discovery.stopDiscovery()
```

## Server-initiated connections

``ClientAdvertiser`` publishes a `_sendspin._tcp` service and listens for incoming WebSocket connections:

```swift
let advertiser = ClientAdvertiser(
    name: "Living Room",
    port: SendspinDefaults.clientPort
)
try await advertiser.start()

for await connection in advertiser.connections {
    try await client.acceptConnection(connection)
}
```

## Lifecycle

Both ``ServerDiscovery`` and ``ClientAdvertiser`` are actors with a one-shot lifecycle. Once stopped, they cannot be restarted — create a new instance instead. Attempting to use a stopped instance throws ``TerminatedError``.
