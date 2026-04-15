# Audio Pipeline

How SendspinKit decodes, schedules, and plays synchronized audio.

## Overview

The audio pipeline is fully managed by ``SendspinClient`` when the `player` role is active. Understanding the pipeline is useful for debugging, tuning buffer sizes, or implementing custom audio processing.

## Pipeline stages

Audio flows through four stages:

1. **Transport** — Binary audio chunks arrive over WebSocket with server timestamps and codec headers.

2. **Decoding** — Chunks are decoded to normalized 32-bit integer PCM. The decoder is selected automatically based on the negotiated codec:
   - **PCM** — Zero-copy passthrough (up to 192kHz/32-bit)
   - **Opus** — Low-latency lossy decoding (8-48kHz)
   - **FLAC** — Lossless decoding with hi-res support (up to 192kHz/24-bit)

3. **Scheduling** — Decoded chunks enter a priority queue sorted by playback timestamp. The scheduler converts server timestamps to local time using the clock synchronizer's offset. Chunks more than 50ms late are dropped.

4. **Playback** — An `AudioQueue` pulls samples from a ring buffer at the hardware sample rate. A sync correction module applies frame-level drop/insert to compensate for clock drift.

## Clock synchronization

Precise playback timing depends on accurate clock sync between client and server. The clock synchronizer runs NTP-style ping/pong exchanges and applies a Kalman-style time filter to converge on a stable offset estimate.

The sync offset is used by the scheduler to convert server-domain timestamps to local monotonic time for sample-accurate playback.

## Buffer configuration

``PlayerConfiguration/bufferCapacity`` controls the size of the PCM ring buffer in bytes. Larger buffers absorb more network jitter but increase memory usage and latency:

| Buffer Size | Duration (48kHz stereo 16-bit) | Use Case |
|-------------|-------------------------------|----------|
| 256 KB | ~1.3 seconds | Low-latency monitoring |
| 1 MB | ~5.5 seconds | Typical playback |
| 4 MB | ~22 seconds | Unreliable networks |

## Custom audio processing

To access raw audio data for visualization or effects, enable ``PlayerConfiguration/emitRawAudioEvents`` and listen for ``ClientEvent/rawAudioChunk(data:serverTimestamp:)`` events. You can also provide a process callback via ``PlayerConfiguration/processCallback`` that runs inline in the audio pipeline before scheduling.
