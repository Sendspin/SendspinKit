# SendspinKit Examples

> **Work in Progress**: These examples are under active development. APIs may change, and some features may be incomplete. Feedback and contributions welcome!

This directory contains standalone example packages demonstrating various SendspinKit features. Each example is self-contained and can be copied as a starting point for your own projects.

## Quick Start

All examples require a running Sendspin server. Connect via `--server <url>` or use `--discover` to find servers on your local network.

```bash
# Navigate to any example
cd Examples/DiscoveryExample

# Build
swift build

# Run with discovery
swift run DiscoveryExample --discover

# Or specify server directly
swift run DiscoveryExample --server ws://192.168.1.100:8927
```

## Examples

| Example | Description | Key Features |
|---------|-------------|--------------|
| [CLIPlayer](CLIPlayer/) | Full-featured command-line player | Audio playback, TUI interface, all codecs |
| [DiscoveryExample](DiscoveryExample/) | mDNS/Bonjour server discovery | Network scanning, server metadata |
| [MetadataClient](MetadataClient/) | Display-only client | Track info without audio playback |
| [ControllerClient](ControllerClient/) | Remote volume/mute control | Silent player pattern, interactive commands |
| [MultiCodecPlayer](MultiCodecPlayer/) | Codec format negotiation | PCM/Opus/FLAC, hi-res audio, priority selection |
| [ErrorRecovery](ErrorRecovery/) | Robust reconnection patterns | Exponential backoff, error classification |
| [ClockSyncDiagnostics](ClockSyncDiagnostics/) | Clock synchronization stats | Offset, RTT, drift, NTP-style sync |

## Common CLI Patterns

All examples use consistent command-line arguments:

```
--server <url>      WebSocket URL (e.g., ws://192.168.1.100:8927)
--discover          Auto-discover servers via mDNS
--timeout <sec>     Discovery/connection timeout (default: 5)
--verbose           Extra logging output
```

## Learning Path

**Getting Started:**
1. **DiscoveryExample** - Learn how to find Sendspin servers on your network
2. **MetadataClient** - Understand the event stream and track metadata

**Player Development:**
3. **MultiCodecPlayer** - Learn format negotiation and codec selection
4. **ControllerClient** - Understand the silent player pattern for control-only clients

**Production Readiness:**
5. **ErrorRecovery** - Implement robust reconnection with exponential backoff
6. **ClockSyncDiagnostics** - Debug synchronization issues

**Full Implementation:**
7. **CLIPlayer** - See a complete player implementation with all features

## Project Structure

Each example follows the same structure:

```
ExampleName/
├── Package.swift          # Swift package manifest
├── README.md              # What it demonstrates, how to run
├── .gitignore             # Excludes .build/ and .swiftpm/
└── Sources/ExampleName/
    └── main.swift         # Entry point with ABOUTME header
```

Examples reference SendspinKit via relative path (`../..`) so they work within this repository structure.

## Requirements

- macOS 14+ (Sonoma)
- Swift 6.0+
- A running Sendspin server

## Building All Examples

```bash
# From the Examples directory
for dir in */; do
    if [ -f "$dir/Package.swift" ]; then
        echo "Building $dir..."
        (cd "$dir" && swift build)
    fi
done
```

## Contributing

When adding new examples:

1. Create a new directory with `Package.swift` referencing SendspinKit via `path: "../.."`
2. Add `.gitignore` with `.build/` and `.swiftpm/`
3. Include `// ABOUTME:` header comments in source files
4. Write a comprehensive README explaining the feature demonstrated
5. Update this file's examples table
