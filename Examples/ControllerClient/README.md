# ControllerClient

A demonstration of the "silent player" pattern - playback control without local audio output.

## What This Example Demonstrates

This example shows how to create a **silent player** that can send control commands without playing audio locally. It uses the player role with minimal configuration but doesn't consume audio chunks. This is useful for:

- Remote control applications
- Headless automation systems
- Multi-room audio control panels
- Testing player control functionality

## Silent Player vs Full Player

| Aspect | Silent Player | Full Player |
|--------|---------------|-------------|
| Audio playback | No - control only | Yes - plays audio |
| Audio data | Received but not consumed | Received and played |
| Resource usage | Low (no audio output) | Higher (audio processing) |
| Control commands | Can send (volume, mute) | Can send (volume, mute) |
| Use case | Remote controls, automation | Actual audio output |

## Why Not Use controller@v1 Role?

The `controller@v1` role exists in the protocol for future multi-room scenarios where one client controls OTHER players. Currently, SendspinKit's control methods (`setVolume`, `setMute`) only work when you have a player role because they control the local player instance.

The "silent player" pattern demonstrated here is more practical for current use cases - a player that participates in the session for control purposes but doesn't output audio.

## Available Control Commands

The current Sendspin protocol supports these control commands:

- **Volume control** - Set volume from 0-100%
- **Mute/Unmute** - Toggle audio muting

The SendspinKit API provides:
- `client.setVolume(_ volume: Float)` - Volume from 0.0 to 1.0
- `client.setMute(_ muted: Bool)` - Set mute state

## How It Works

1. **Role declaration**: Client requests `player@v1` role during handshake
2. **Minimal config**: Uses minimal PlayerConfiguration (small buffer, one format)
3. **Silent operation**: Audio chunks are received but not consumed/played
4. **Control commands**: Sends volume/mute commands via `SendspinClient` API
5. **Status monitoring**: Receives metadata updates to show what's playing
6. **Interactive UI**: Simple keyboard interface for immediate control

## Building and Running

```bash
# Build the example
swift build

# Run with auto-discovery
swift run ControllerClient --discover

# Or specify a server URL directly
swift run ControllerClient --server ws://localhost:8080

# Verbose mode shows detailed events
swift run ControllerClient --discover --verbose
```

## Interactive Controls

Once connected, use these single-key commands:

- `+` or `=` - Increase volume by 10%
- `-` or `_` - Decrease volume by 10%
- `m` - Mute audio
- `u` - Unmute audio
- `q` - Quit

The display shows real-time volume status with a visual bar:
```
🔊 Volume: [████████████░░░░░░░░] 60%
```

## Code Structure

### Main Components

1. **ArgumentParser CLI** - Handles `--server` or `--discover` options
2. **SendspinClient** - Created with `player@v1` + `metadata@v1` roles (silent player pattern)
3. **Event monitoring** - Async task to display metadata and status
4. **Command loop** - Raw terminal input for immediate key response
5. **Control methods** - `setVolume()` and `setMute()` API calls

### Key Implementation Details

**Role Configuration:**
```swift
// Minimal player configuration - we won't actually play audio
let config = PlayerConfiguration(
    bufferCapacity: 65536,  // Small buffer
    supportedFormats: [
        AudioFormatSpec(codec: .pcm, channels: 2, sampleRate: 48_000, bitDepth: 16)
    ]
)

let client = SendspinClient(
    clientId: UUID().uuidString,
    name: "ControllerClient",
    roles: [.playerV1, .metadataV1],  // Player role for control + metadata
    playerConfig: config
)
```

**Volume Control:**
```swift
// User presses '+' to increase volume
currentVolume = min(100, currentVolume + 10)
let volumeFloat = Float(currentVolume) / 100.0  // Convert to 0.0-1.0
await client.setVolume(volumeFloat)
```

**Mute Control:**
```swift
// User presses 'm' to mute
await client.setMute(true)
```

**Raw Terminal Input:**
The example uses raw mode for immediate key response without waiting for Enter:
```swift
let originalTermios = enableRawMode()
defer { disableRawMode(originalTermios) }

while let char = readChar() {
    switch char {
    case "+": // Handle immediately
    // ...
    }
}
```

## Teaching Points

### 1. Silent Player Pattern

A "silent player" is a player that participates in the session but doesn't output audio:
- **Full Player** - Receives audio, decodes it, plays it via system audio
- **Silent Player** - Receives audio, doesn't consume it, can control volume/mute
- **Metadata Client** - Receives metadata only, no audio or control

This pattern is useful when you want control capabilities without audio output overhead.

### 2. Minimal Configuration

Silent players use minimal configuration:
- Small buffer allocation (won't be used much)
- Single basic format support (48kHz PCM is universal)
- No need for hi-res format support

This makes them lighter than full players but heavier than pure metadata clients.

### 3. Async Control Flow

Control commands are async because they:
- Send messages over WebSocket
- Update server state
- May trigger state broadcasts to other clients

The pattern is:
```swift
await client.setVolume(0.5)  // Async send to server
// Server updates its state and notifies all clients
```

### 4. State Synchronization

Controllers track local state (current volume/mute) to provide UI feedback. In production:
- Server is source of truth
- Controllers should listen for state updates from server
- Handle conflicts (multiple controllers, server overrides)

### 5. Terminal Raw Mode

The example demonstrates low-level terminal control for interactive UIs:
- `tcgetattr` / `tcsetattr` - Get/set terminal attributes
- `ICANON` - Disable line buffering
- `ECHO` - Disable character echo
- Restore on exit - Clean terminal state

## Protocol Notes

The Sendspin protocol currently defines these player state controls:
- `volume` - Set playback volume (0-100)
- `mute` - Set mute state (true/false)

These are sent to the server via `client/state` messages and affect the local player's output.

Future protocol extensions may add server-coordinated commands:
- Transport controls (play/pause/skip) - Server-level playback
- Seek commands - Position in track
- Group controls - Multi-room coordination

The `controller@v1` role is reserved for future server-coordinated control scenarios where one client can affect other players in the group.

## Testing

To test this example:

1. Start a Sendspin server with active playback
2. Connect the ControllerClient
3. Use `+/-` keys to adjust volume
4. Use `m/u` keys to mute/unmute
5. Observe changes on the actual player output

You can run multiple controllers simultaneously to test multi-client scenarios.

## Related Examples

- **MetadataClient** - Metadata-only role (no audio, no control)
- **CLIPlayer** - Full player role (audio + control + metadata)
- **MinimalPlayer** - Minimal player implementation

## Further Reading

- See `SendspinClient.swift` for complete control API
- See `SendspinMessage.swift` for protocol message definitions
- See Sendspin Protocol Specification for role semantics
