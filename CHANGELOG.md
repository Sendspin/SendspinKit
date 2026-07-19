# Changelog

All notable changes to SendspinKit will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added
- **Visualizer@v1 role implementation** (previously a placeholder). `SendspinClient`
  accepts a `visualizerConfig: VisualizerConfiguration` declaring feature types
  (loudness / beat / f_peak / spectrum / peak / pitch), spectrum binning, buffer
  capacity, and `rate_max`; the negotiated `stream/start` visualizer announcement
  surfaces as `ClientEvent.visualizerStreamStarted(StreamVisualizerConfig)` and
  `currentVisualizerStream`.
- Binary visualizer frame types 17–21 (beat, f_peak, spectrum, peak, pitch) are now
  recognized and routed; `VisualizerData` carries the feature `type` and offers a
  typed `frame(spectrumBins:)` decode into the new `VisualizerFrame` enum.
- Conformance fixtures for the visualizer role, hand-derived from aiosendspin 6.0.5
  (`Tests/SendspinKitTests/Models/VisualizerModelTests.swift`).

### Fixed
- **`client/hello` no longer encodes `visualizer@v1_support` as an empty `{}`** —
  the shape aiosendspin 6.x hard-rejects, which made advertising the visualizer role
  break the whole handshake against Music Assistant 2.9.x. The support object is now
  built from a validated `VisualizerConfiguration`, and constructing a client that
  advertises `visualizer@v1` without one throws
  `ConfigurationError.visualizerRoleRequiresConfiguration`.

### Changed
- `BinaryMessageType.visualizerData` (16) is renamed `.visualizerLoudness` to match
  the per-feature ID allocation in aiosendspin's `BinaryMessageType` (internal type).

## [0.3.0] - 2025-10-26

### Added
- Opus audio codec support via native `AVAudioConverter` (`kAudioFormatOpus`)
- FLAC audio codec support using flac-binary-xcframework (v0.2.0)
- Comprehensive codec documentation in docs/CODEC_SUPPORT.md
- ogg-binary-xcframework dependency for FLAC framework support
- Native Opus decoding through AVAudioConverter with Int32 PCM output for the playback pipeline

### Changed
- AudioDecoder now uses codec-specific minimal conversion paths: PCM 16/32-bit passthrough, PCM 24-bit unpacking, and Int32 output for compressed codecs
- AudioDecoderFactory supports opus and flac codec types
- Updated README with codec support section and multi-codec examples
- Player configuration examples now advertise all supported codecs

### Fixed
- Critical FLAC decoder data accumulation bug (memory leak in pending buffer)
- Improved error handling in FLAC decoder with proper error callback
- FLAC decoder now correctly removes consumed bytes from pending buffer

## [0.2.0] - 2025-10-25

### Added
- Initial working implementation of ResonateKit
- Player role with synchronized audio playback
- Controller role for playback control
- Metadata role for track information display
- WebSocket-based communication with Resonate servers
- Clock synchronization using NTP-style algorithm with Kalman filtering
- AudioScheduler with timestamp-based playback scheduling
- PCM audio decoder (16-bit, 24-bit, 32-bit support)
- mDNS/Bonjour server discovery
- Example CLIPlayer application

### Changed
- Migrated from Go reference implementation to Swift
- Implemented Swift 6.0 strict concurrency model

### Fixed
- Critical race condition in WebSocket connection
- Binary message type 1 handling
- Connection continuation handling for server communication

## [0.1.0] - 2025-10-20

### Added
- Initial project structure
- Basic protocol message types
- WebSocket transport layer
- Core client architecture

[0.3.0]: https://github.com/YOUR_ORG/ResonateKit/releases/tag/v0.3.0
[0.2.0]: https://github.com/YOUR_ORG/ResonateKit/releases/tag/v0.2.0
[0.1.0]: https://github.com/YOUR_ORG/ResonateKit/releases/tag/v0.1.0
