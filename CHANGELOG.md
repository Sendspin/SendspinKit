# Changelog

All notable changes to SendspinKit will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased] - Noise spec alignment

### Breaking
- Replaced the plaintext session handshake with mandatory Noise encryption; clients now require a stable `SendspinIdentity` and host-owned secret-key persistence.
- Replaced the old client identifier and handshake surface with identity-based `SendspinClient` initialization and encrypted transport framing. `client/hello` no longer carries `trust_level`, artwork support, or mutable player commands; support objects now contain only their protocol-defined capabilities.
- Removed the protocol `management` namespace, responder, persistence hooks, and remote management operations. `PairingManagementConfiguration` remains the host-local pairing settings value; pairing-window opening is a host gesture/API concern.
- Replaced `requestPlayerFormat`/`requestArtworkFormat` and `stream/request-format` with `setPlayerFormatPreference` and `setArtworkChannelPreference`, which publish state preferences.
- Changed `client/hello.supported_pair_methods` from an array to a keyed object, with method-specific descriptors. A client advertises Pairing PSK and at most one pairing-code method; code pairing is Sentinel-only, and `psk_category` now binds each handshake candidate to its credential category.
- Changed Noise fragmentation to the single type-1 framing format with explicit first/last flags and reserved-bit validation. Player audio remains binary type 4 and now includes the `send_ahead` header field.
- Renamed output-delay wire keys to `output_delay_ms` and `set_output_delay`.
- Changed `client/state` from deltas to full snapshots, including mutable player commands, artwork channels, and visualizer configuration. Artwork configuration no longer belongs in `client/hello`.
- Replaced one-message artwork images with announce/part/cancel transfers, and removed BMP support; artwork formats are JPEG and PNG.

### Added
- Added dynamic six-digit and QR (`SP:1`) pairing-code flows plus static eight-digit code provisioning through `PairingConfiguration`, with `ClientEvent.pairingCodeChanged(_:)`, `ClientEvent.pairingAttemptEnded(_:)`, `SendspinClient.openPairingWindow()`, and `SendspinClient.cancelPairingAttempt()`.
- Added optional server-supplied digit-audio packs and speaker capability descriptors. Validated packs are attached to digit pairing emissions for the host app to decode and play; Sentinel fallback handles an initial pairing-PSK miss.
- Added visualizer state configuration for beat, loudness, peak, and spectrum data, including rate and spectrum parameters.
- Added scheduled metadata, color, and artwork updates using the current best clock estimate.
- Added `requiredLeadTimeMs` and `minBufferMs` player configuration, with measured buffer-depth publication through full state snapshots.
- Added dynamic pairing failure-counter provider hooks and host-local pairing configuration updates without returning the static secret.
- Added the pinned `jedisct1/swift-sodium` 0.9.1 dependency and the `CElligator` target. `CElligator` vendors libsodium 1.0.21 field-operation sources at revision `3e7548c62f68909461a67f396be0494584a7aae4` for the RFC 9380 Elligator2 composition; the linked `Clibsodium.xcframework` provenance and checksum are documented in `Sources/CElligator/README.md`.
- The selected dependency advertises watchOS slices, but watchOS 10 pairing-code compilation remains locally unverified when the required SDK is unavailable.

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
