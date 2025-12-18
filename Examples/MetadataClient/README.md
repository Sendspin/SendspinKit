# MetadataClient Example

A metadata-only client demonstration for SendspinKit. This example shows how to connect to a Sendspin server and receive track metadata without playing audio.

## What This Demonstrates

1. **Metadata-Only Role**: Connecting with `metadata@v1` role instead of `player@v1`
2. **Event Handling**: Using `for await event in client.events` to process server events
3. **Server Discovery**: Auto-discovering servers on the local network with mDNS
4. **Real-Time Display**: Showing track information as it changes
5. **Minimal Resource Usage**: No audio playback, decoding, or buffering

## Use Cases

This pattern is useful for:

- **Display Screens**: "Now Playing" displays that don't need audio
- **Home Automation**: Integration with smart home systems
- **Logging/Monitoring**: Recording playback history without consuming audio
- **Multi-Room Controllers**: UI controllers that display but don't play audio
- **Testing**: Verifying metadata delivery without audio complexity

## Building

```bash
cd Examples/MetadataClient
swift build
```

## Running

### With Auto-Discovery

Find and connect to a server automatically:

```bash
swift run MetadataClient --discover
```

### With Explicit Server URL

Connect to a specific server:

```bash
swift run MetadataClient --server ws://localhost:8080
```

### With Verbose Output

Show detailed event information:

```bash
swift run MetadataClient --discover --verbose
```

## Command-Line Options

- `--server <url>` or `-s <url>`: Server URL to connect to
- `--discover` or `-d`: Auto-discover server on local network
- `--timeout <seconds>` or `-t <seconds>`: Discovery timeout (default: 5)
- `--verbose` or `-v`: Show detailed event information

**Note**: Must specify either `--server` or `--discover`, but not both.

## Expected Output

When running, you'll see output like:

```
🎵 Sendspin Metadata Client
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

🔍 Discovering Sendspin servers...
⏱️  Timeout: 5 seconds

✅ Found server: My Sendspin Server
   URL: ws://192.168.1.100:8080

🔌 Connecting to ws://192.168.1.100:8080...
✅ Connected!

Monitoring metadata (press Ctrl-C to exit)...
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

🎵 Now Playing:
   Title:  Hotel California
   Artist: Eagles
   Album:  Hotel California
   Duration: 6:30

🎵 Now Playing:
   Title:  Bohemian Rhapsody
   Artist: Queen
   Album:  A Night at the Opera
   Duration: 5:55
```

## How It Works

### Metadata-Only Connection

Unlike the CLIPlayer example which requests the `player@v1` role, MetadataClient only requests `metadata@v1`:

```swift
let client = SendspinClient(
    clientId: UUID().uuidString,
    name: "MetadataClient",
    roles: [.metadataV1],  // Metadata-only!
    playerConfig: nil       // No player config needed
)
```

This tells the server:
- Don't send audio chunks
- Don't expect playback commands
- Only send metadata updates

### Event Processing

The client uses SendspinKit's async event stream:

```swift
for await event in client.events {
    switch event {
    case let .metadataReceived(metadata):
        // Display track info
        print("Title: \(metadata.title ?? "Unknown")")
        print("Artist: \(metadata.artist ?? "Unknown")")
        // ...
    // Handle other events...
    }
}
```

### Why This Matters

In the Sendspin protocol, clients negotiate capabilities during the handshake. By requesting only the metadata role:

1. **Bandwidth Savings**: Server won't send multi-megabyte audio chunks
2. **CPU Savings**: No decoding, buffering, or playback
3. **Memory Savings**: No audio buffers needed
4. **Simpler Code**: No audio configuration or state management

This makes metadata-only clients perfect for low-power devices like Raspberry Pi displays, embedded systems, or cloud-based monitoring services.

## Code Structure

- **Validation**: Ensures valid command-line arguments
- **Discovery**: Optional mDNS server discovery
- **Connection**: Metadata-only client setup
- **Event Monitoring**: Async event stream processing
- **Display**: Clean console output with track changes

## Teaching Points

1. **Role Negotiation**: Different roles enable different capabilities
2. **Async Streams**: Modern Swift concurrency for event processing
3. **Resource Efficiency**: Only request what you need
4. **Change Detection**: Track state to avoid duplicate displays
5. **Clean Shutdown**: Graceful handling of Ctrl-C (via async task cancellation)

## Extending This Example

You could extend this to:
- Request `artwork@v1` role to receive album art
- Save metadata to a database
- Send track info to external APIs
- Display on an e-ink screen or LED matrix
- Create a web dashboard
- Log playback history

## Comparison to CLIPlayer

| Feature | MetadataClient | CLIPlayer |
|---------|---------------|-----------|
| Roles | `metadata@v1` | `player@v1`, `metadata@v1` |
| Audio | None | Full playback |
| Config | None needed | PlayerConfiguration required |
| Resources | Minimal | Buffers, decoder, audio output |
| Use Case | Display/monitoring | Actual playback |

## License

Apache 2.0 (same as SendspinKit)
