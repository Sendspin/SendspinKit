# SendspinKit Examples Suite Design

**Date**: 2025-12-17
**Status**: Approved

## Overview

Six standalone executable examples demonstrating specific SendspinKit features. Each example is self-contained, requires a real Sendspin server, and serves as both documentation and a copyable starting point.

## Structure

```
Examples/
├── CLIPlayer/              # (existing)
├── DiscoveryExample/       # mDNS server discovery
├── MetadataClient/         # Track info display only
├── ControllerClient/       # Remote playback control
├── MultiCodecPlayer/       # Codec negotiation demo
├── ErrorRecovery/          # Reconnection patterns
└── ClockSyncDiagnostics/   # Sync accuracy display
```

## Individual Examples

### 1. DiscoveryExample

Demonstrates mDNS/Bonjour server discovery. Scans the network, lists found servers with metadata (name, URL, port), and exits.

```bash
swift run DiscoveryExample --timeout 5
```

### 2. MetadataClient

Connects as metadata-only role (`metadata@v1`). Displays track title, artist, album, duration, and progress in real-time. No audio playback.

```bash
swift run MetadataClient --server ws://192.168.1.100:8080
```

### 3. ControllerClient

Connects as controller role (`controller@v1`). Interactive commands: play, pause, skip, volume, mute.

```bash
swift run ControllerClient --server ws://192.168.1.100:8080
```

### 4. MultiCodecPlayer

Player demonstrating format negotiation. Explicitly requests codec priority and displays which format the server selected.

```bash
swift run MultiCodecPlayer --server ws://... --prefer opus,flac,pcm
```

### 5. ErrorRecovery

Player with robust reconnection logic. Demonstrates handling disconnects, exponential backoff, and state recovery.

```bash
swift run ErrorRecovery --server ws://...
```

### 6. ClockSyncDiagnostics

Displays real-time clock synchronization stats: offset, RTT, drift. Useful for debugging sync issues.

```bash
swift run ClockSyncDiagnostics --server ws://...
```

## Shared Patterns

### Common CLI Arguments

All examples use `ArgumentParser` with consistent flags:

- `--server <url>` - WebSocket URL (required unless discovery finds one)
- `--discover` - Auto-discover and connect to first found server
- `--timeout <seconds>` - Connection/discovery timeout (default: 5)
- `--verbose` - Extra logging

### Output Style

Clean, readable terminal output using `print()`. No TUI complexity - examples should be readable as code.

### Error Handling

```swift
do {
    try await client.connect(to: url)
} catch {
    print("Connection failed: \(error)")
    exit(1)
}
```

### Event Loop

```swift
for await event in client.events {
    switch event {
    case .relevantCase(let data):
        // Handle relevant events for this example
    default:
        break // Ignore events not relevant to this feature
    }
}
```

### Code Style

- Each `main.swift` has `// ABOUTME:` header
- Inline comments explain *why*, not just *what*
- No shared "ExamplesCommon" module - each example is fully self-contained

## Documentation

### Per-Example README

- What feature it demonstrates
- How to run (with real command examples)
- Expected output sample
- Key code patterns to notice

### Root Examples/README.md

Overview page listing all examples with one-liner descriptions and quick-start commands.

## Package.swift Changes

Add six new executable products:

- `DiscoveryExample`
- `MetadataClient`
- `ControllerClient`
- `MultiCodecPlayer`
- `ErrorRecovery`
- `ClockSyncDiagnostics`

All depend on:
- `SendspinKit`
- `swift-argument-parser`

## Testing

No automated tests for examples. They require a real server and serve as manual integration tests. This matches the existing CLIPlayer pattern and no-mocks preference.
