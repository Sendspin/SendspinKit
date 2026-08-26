# Changelog

All notable changes to SendspinKit will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased] - Noise spec alignment

### Breaking
- Replaced the plaintext session handshake with mandatory Noise encryption; clients now require a stable `SendspinIdentity` and its host-owned secret-key persistence.
- Replaced the old client identifier and handshake surface with identity-based `SendspinClient` initialization and encrypted transport framing.
- Added Pairing PSK support with host-provided `PairingConfiguration` and `PairingRecordStore`, `PairingToken` (`SP:0`) setup tokens, trust levels, pairing events, and management-role record/configuration operations.
- Added the management role responder and updated public event/state names for the new protocol session flow.
- Host applications must update persistence providers for pairing records and the renamed output-delay APIs.

### Compatibility
- The wire continues to use `static_delay_ms` and `set_static_delay` deliberately until deployed servers adopt the spec's `output_delay_ms` and `set_output_delay` names.

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
