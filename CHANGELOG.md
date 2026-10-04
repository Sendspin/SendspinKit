# Changelog

All notable changes to SendspinKit will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased] - Spec alignment

### Breaking
- Player catalogs require FLAC or PCM and report `missingLosslessFormat` otherwise.
- `requireCurrentOutput` reports `noMatchingLosslessFormat` when its output-filtered catalog contains neither FLAC nor PCM.
- `PairingPresentation.speaker` and `.displayAndSpeaker` are parameterless and require host-provided speech.

### Added
- `ServerErrorReason` and `SendspinClientError.connectionRefused(_:)` expose unauthenticated setup refusals for diagnostics.
- `ClientEvent.pairingAttemptSuperseded(_:)` identifies an attempt replaced or abandoned by server activation.
- `cancelPairing(attemptID:)` accepts `pairingWindow.attemptID` to close a surviving window and end its current attempt.
- `setVisualizerPreference(_:)` publishes dynamic visualizer preferences.
- Controller command errors distinguish `controllerStateUnavailable` from `controllerCommandUnsupported`.

### Changed
- `PairingCodeEmission.languages` supplies the server's language priority list for host-provided speech.
- `openPairingWindow(for:)` resets the emitted-round budget with one operator gesture, including an already-open window.

### Removed
- Server-supplied digit audio descriptors, packs, clips, binary handling, and `PairingCodeEmission.digitAudioPack` are absent.
- `ConfigurationError.emptyVisualizerTypes` is absent because empty requests are valid.

### Fixed
- Player streams emit `streamStarted` once on their first successful engine outcome and `streamFormatChanged` on later outcomes.
- Server reactivation updates session state without repeating `serverConnected` with an empty name.
- Activation admission follows the credential activity table and permits simultaneous playback and pairing without quiescing playback.
- Removed versioned roles clear state, scheduled updates, buffers, and temporary output while unchanged roles retain state.
- Artwork stream end and role removal clear current artwork and invalidate pending image deliveries.
- Re-handshake preserves roles, streams, buffers, artwork transfers, and clock state without repeating either hello.
- New-key application messages wait for `server/activate` during re-handshake.
- Every activation uses the host's shared unpaired-access policy.
- Pairing PSK init includes the pairing index and remains adjacent to finalize under one outbound acquisition.
- CPace round numbers are attempt-local and the device-wide budget counts only emitted dynamic codes.
- Dynamic attempts send one `client/pair-init` and wait for the server's next round after `client/pair-retry`.
- Static pairing windows survive attempt timeout and supersession and close on success, five failed confirmations, disconnect, operator cancellation, or expiry.
- Superseding pairing activations replace attempt state without disconnecting or persisting an abandoned PSK.
- Only client abort opens the silent-discard interval, which ends at the next activation; other pairing sequence violations close silently.
- Active player configuration updates preserve buffered audio and identical announcements preserve the timeline.
- Opus validation and format matching ignore bit depth while PCM and FLAC retain depth validation.
- An advertised session is no longer disconnected when its admission task is cancelled or times out after adoption.
- Controller commands validate against the latest connection-owned `supported_commands`.
- Disabled artwork channels decode without format or dimensions.
- Visualizer streams accept empty type subsets and validate spectrum only when streamed.
- Unavailable clients discard audio, artwork, and visualizer data while preserving artwork byte accounting.

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
