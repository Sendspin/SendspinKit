# MultiCodecPlayer

A demonstration of codec format negotiation with SendspinKit.

## Overview

This example shows how to configure preferred audio formats and observe the negotiation process between client and server. The Sendspin protocol supports multiple audio codecs (Opus, FLAC, PCM) with varying sample rates and bit depths, and negotiation ensures the best compatible format is selected.

## Format Negotiation

### How It Works

1. **Client Specifies Preferences**: The client provides an array of `AudioFormatSpec` in priority order (most preferred first)
2. **Server Selects Format**: The server chooses the first format from the client's list that it can provide
3. **Stream Starts**: The `.streamStarted(AudioFormatSpec)` event announces the negotiated format
4. **Audio Flows**: All subsequent audio data uses the negotiated format

### Priority Order Matters

The order of formats in the `supportedFormats` array is critical:

```swift
let config = PlayerConfiguration(
    bufferCapacity: 1024 * 1024,
    supportedFormats: [
        // 1st choice: Hi-res FLAC (lossless, 192kHz/24-bit)
        AudioFormatSpec(codec: .flac, channels: 2, sampleRate: 192000, bitDepth: 24),

        // 2nd choice: Standard FLAC (lossless, 48kHz/24-bit)
        AudioFormatSpec(codec: .flac, channels: 2, sampleRate: 48000, bitDepth: 24),

        // 3rd choice: Opus (lossy, low latency)
        AudioFormatSpec(codec: .opus, channels: 2, sampleRate: 48000, bitDepth: 16),

        // 4th choice: PCM fallback (uncompressed)
        AudioFormatSpec(codec: .pcm, channels: 2, sampleRate: 48000, bitDepth: 16)
    ]
)
```

The server will try to match formats in this order. If it can't provide 192kHz FLAC, it will try 48kHz FLAC, then Opus, then PCM.

## Supported Codecs

### Opus
- **Type**: Lossy compression
- **Best for**: Low latency, voice, real-time music
- **Compression**: ~8:1 to 12:1
- **Latency**: Very low (designed for VoIP)
- **Quality**: Transparent at 128+ kbps

### FLAC
- **Type**: Lossless compression
- **Best for**: Archival, audiophile playback
- **Compression**: ~2:1 to 3:1
- **Latency**: Low
- **Quality**: Bit-perfect (identical to source)

### PCM
- **Type**: Uncompressed raw audio
- **Best for**: When CPU/bandwidth is not constrained
- **Compression**: None (full bitrate)
- **Latency**: Minimal
- **Quality**: Perfect (uncompressed)

## Hi-Res Audio Support

SendspinKit supports high-resolution audio formats:

- **Sample Rates**: Up to 384kHz (common: 44.1kHz, 48kHz, 96kHz, 192kHz)
- **Bit Depths**: 16-bit, 24-bit, 32-bit
- **Channels**: 1 (mono) to 32 channels

Example hi-res specification:
```swift
AudioFormatSpec(codec: .flac, channels: 2, sampleRate: 192000, bitDepth: 24)
```

This represents 192kHz/24-bit stereo FLAC, which requires:
- Uncompressed bitrate: 9,216 kbps
- Compressed (FLAC): ~3,000-4,500 kbps

## Usage

### Basic Usage

Connect to a specific server and use default format preferences:

```bash
swift run MultiCodecPlayer --server ws://localhost:8927
```

### Discovery Mode

Discover servers on the local network:

```bash
swift run MultiCodecPlayer --discover
```

### Custom Format Preferences

Specify preferred codecs in priority order:

```bash
# Prefer FLAC, then Opus, then PCM
swift run MultiCodecPlayer --server ws://localhost:8927 --prefer flac,opus,pcm
```

### Hi-Res Audio

Request high-resolution audio:

```bash
# 192kHz/24-bit FLAC
swift run MultiCodecPlayer --server ws://localhost:8927 \
    --prefer flac \
    --sample-rate 192000 \
    --bit-depth 24
```

### Extended Playback

Monitor the stream for a specific duration:

```bash
# Play for 30 seconds
swift run MultiCodecPlayer --server ws://localhost:8927 --duration 30

# Monitor indefinitely (Ctrl+C to stop)
swift run MultiCodecPlayer --server ws://localhost:8927 --duration 0
```

## Command-Line Options

- `--server <url>`: Server WebSocket URL (e.g., `ws://localhost:8927`)
- `--discover`: Discover servers instead of connecting directly
- `--timeout <seconds>`: Discovery timeout in seconds (default: 5)
- `--prefer <codecs>`: Preferred codecs in priority order, comma-separated (default: `flac,opus,pcm`)
- `--sample-rate <rate>`: Preferred sample rate in Hz (default: 48000)
- `--bit-depth <depth>`: Preferred bit depth - 16, 24, or 32 (default: 24)
- `--duration <seconds>`: Duration to play audio in seconds, 0 for indefinite (default: 10)

## What You'll See

When you run the example, it will:

1. Display your format preferences in priority order
2. Connect to the server
3. Show a detailed breakdown when the stream starts:
   - What you requested
   - What the server selected
   - Whether you got your first choice
   - Codec characteristics and expected bitrate
4. Monitor incoming audio frames
5. Display a session summary on disconnect

### Example Output

```
🎯 Building format preferences...

  [HIGHEST] FLAC - 192000Hz, 24-bit, stereo
  [Priority 2] OPUS - 48000Hz, 24-bit, stereo
  [Priority 3] PCM - 48000Hz, 24-bit, stereo

🔗 Connecting to: ws://localhost:8927

🔌 Connecting as player...
✅ Connected!

👂 Monitoring stream events...
⏱️  Will play for 10 seconds

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
🎶 STREAM STARTED - Format Negotiation Result
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

📋 What you requested (in priority order):
  1️⃣ FLAC - 192000Hz, 24-bit, 2ch
  2️⃣ OPUS - 48000Hz, 24-bit, 2ch
  3️⃣ PCM - 48000Hz, 24-bit, 2ch

✅ What the server selected:
   FLAC - 192000Hz, 24-bit, 2ch

🎯 Server selected your FIRST CHOICE format!

📊 Codec characteristics:
   FLAC: Lossless compression, bit-perfect audio
   Typical compression: 2:1 to 3:1

📈 Uncompressed bitrate: 9216 kbps

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
```

## Understanding Negotiation Outcomes

### Best Case: First Choice Match
```
🎯 Server selected your FIRST CHOICE format!
```
The server supports your preferred format. You're getting exactly what you asked for.

### Fallback: Lower Priority Match
```
⚠️  Server selected your choice #2
   This means the server couldn't provide your higher priority formats
```
The server doesn't support your top preference but found a match lower in your priority list. This is normal when requesting hi-res formats that the server may not support.

### Mismatch: Unexpected Format
```
❌ Server selected a format NOT in your preference list
   This might indicate a protocol mismatch or server limitation
```
The server selected a format you didn't request. This could indicate a protocol version mismatch or an unusual server configuration.

## Building

```bash
cd Examples/MultiCodecPlayer
swift build
```

## Learning More

This example demonstrates:
- How to construct `AudioFormatSpec` for different codecs
- How to create `PlayerConfiguration` with multiple format preferences
- How to monitor the `.streamStarted` event to see negotiated format
- Understanding codec tradeoffs (latency vs. quality vs. bandwidth)
- Supporting hi-res audio formats (up to 384kHz/32-bit)

For more information, see:
- `AudioFormatSpec.swift` - Format specification structure
- `AudioCodec.swift` - Supported codec enumeration
- `PlayerConfiguration.swift` - Player role configuration
- Sendspin Protocol Specification - Format negotiation protocol
