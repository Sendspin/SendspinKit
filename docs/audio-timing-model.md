# Audio timing model

How a server timestamp becomes a sample at the speaker, what the playback cursor means, and
where the current implementation departs from the model. Written after measuring the departure;
every figure here is observed on a Mac Studio driving a USB DAC at 44.1kHz/2ch/32-bit output.

## The contract

The spec (`spec/roles/player/v1.md`, "Server → Client: Audio Chunks") fixes the target:

> the timestamp indicates when the first audio sample in this chunk should be output

and

> Clients should compensate for any known processing delays (e.g., DAC latency, audio buffer
> delays, amplifier delays) by accounting for these delays when submitting audio to the hardware.

Sync accuracy is "measured at the audio output", so the quantity to get right is **when a sample
is audible**, not when we hand it over. `static_delay_ms` is explicitly *not* the home for output
latency — it covers delay beyond the port (amplifiers, speaker distance). DAC and buffer latency
belong in the client's own scheduling and in `required_lead_time_ms`.

## The invariant

Let `L` be the delay from handing a frame to the output until that frame is audible, and let
`cursor` be the server timestamp of the frame most recently handed over.

A frame handed over at local time `t` is audible at `t + L`, and must be audible at
`local(cursor)`:

```
t + L = local(cursor)   ⟹   expected(t) + L = cursor
```

**The cursor leads `expected` by `L`.** The error signal is therefore

```
error = (expected + L) − cursor
```

`sendspin-rs` computes exactly this, in the local-time domain: `playback_instant −
expected_instant`, where `playback_instant = now + (cpal playback − callback)`. The latency term
appears once, sourced from the backend per callback rather than modelled. Its explicit-latency
API (`ClockSync::server_to_local_instant_with_latency`) belongs to a separate scheduling path and
is deliberately not combined with drift correction.

## What the implementation now does

- The correction formula reads `(expected + L) − cursor`. Three sites shared the old, inverted
  equilibrium — `updateCorrectionSchedule`, `graceExpiryRebaselineCursor` and the reanchor
  target — and are now one definition.
- `L` includes the device path, read from the HAL at `prepare()` (`OutputDeviceLatency`).
- The queue starts on silence at `prepare()`, so the device pays its spin-up during the window
  already being spent buffering.
- The first real frame is placed to the sample: once the queue is running the device consumes at
  exactly the sample rate, so a frame's audible instant is fixed by its position in the stream.
  `AudioQueueGetCurrentTime` gives frames played, `totalFramesEnqueued` gives frames handed over,
  and the difference plus the device path says when the next frame written will be audible.
  Silence pads the gap to its due instant.
- Telemetry carries `startOffset`, `spinUp`, `startPad` and `inFlight`, because
  `graceExpiryRebaselineCursor` still assigns the equilibrium and so `sync` reads ~0 from grace
  expiry onward however far out playback began.

## Measured history of the start error

Each row is the offset playback actually starts at, on the reference setup.

| | startOffset | note |
|---|---|---|
| inverted sign, device path zero | −146,870 µs | invisible; frozen and reported as perfect sync |
| sign corrected, device path measured | +297,935 / +396,532 µs | tracked `spinUp` 1:1 (residual 280–2,455 µs) |
| device pre-warmed | +20,387 / +44,341 / +42,481 µs | decoupled from `spinUp`; one buffer period of jitter |
| first frame placed to the sample | +33,374 … +33,504 µs | **deterministic to 130 µs over 5 runs** |

Spin-up itself is unchanged at 292–413 ms; it is paid, not removed. The pad absorbing the
variation ranged 609–1,383 frames while the resulting offset moved 130 µs.

## `AudioQueueStart` blocks, and dominates what this client calls "spin-up"

`AudioQueueStart` is synchronous. A stack sample shows why:

```
AQ::API::V2Impl::AudioQueueStartWithFlags
  AudioQueueXPC_Bridge::Start
    _dispatch_sync_invoke_and_complete_recurse
      AudioQueueXPC_Server::Start
        AudioQueueObject::Start
```

It is a dispatched, synchronous XPC round trip to the audio server. Measured cost:

| | `AudioQueueStart` | `spinUp` (measured from before the call) |
|---|---|---|
| Mac Studio, USB DAC | 339 ms | 391 ms |
| MacBook, built-in | 233-323 ms | 291-380 ms |

**The device itself wakes in roughly 50 ms.** Earlier revisions of this document attributed
300-400 ms to an idle DAC; that figure was almost entirely this call, because `spinUp` is
stamped before it. Pre-warming is still worth doing, but for the reason that it moves this cost
off the release path — not because the hardware is slow.

`prepare()` runs on the engine's ordered command loop, so whatever this call costs stalls chunk
handling behind it.

## Unresolved: intermittent silence with every counter healthy

On one machine, some runs produce no sound while reporting `late=0 underrun=0 pcmDrop=0`,
`peak=0.2121 gain=1.00`, `silentBufs=0` and a normal sync error. Full-amplitude audio at unity
gain reaches a device that is consuming it, and nothing is heard. In those runs `AudioQueueStart`
blocks for 13.22-13.29 s -- seven readings inside 70 ms of each other, which is a timeout rather
than a wake -- and the whole chunk backlog then arrives in a single burst.

It is intermittent and currently not reproducing. Ruled out by measurement, so do not revisit
without new evidence:

- **Writing silence.** `peak` on a silent run equals `peak` on an audible one.
- **Device selection.** It is the built-in speakers, not Bluetooth or a virtual device.
- **Sample-rate mismatch.** 13,220,152 us at 48 kHz against 13,222,207 us at 44.1 kHz.
- **The pty.** Running the player under `script` versus directly: 238-255 ms against 337-347 ms,
  neither anywhere near 13 s.
- **A slow DAC.** Same machine, same device, 233 ms on a run that worked.

`scripts/smoke-test.sh --sample` captures the player's stacks during startup and prints the
frames under `AudioQueueStart`; a sample taken while the 13 s block is happening is the next
piece of evidence needed.

## Remaining departure — modelled depth against measured depth

The placement measures the pipeline. The correction formula still models it as every allocated
buffer:

```
L_modelled = audioQueueBufferCount * bufferBytes / byteRate + deviceLatency
           = 139,319 + 14,716 = 154,035 µs
```

A running queue does not hold every buffer unplayed. Logged at one placement instant:

```
inFlight 4,811 frames = 109,092 µs   deviceLatency 14,716 µs   total 123,808 µs
```

and the whole residual follows from the difference:

```
startOffset = L_modelled − (inFlight + deviceLatency) = 154,035 − 123,808 = 30,227 µs
```

against 33,504 µs measured — the remaining ~3 ms is unattributed. Sampled during playback,
`inFlight` ranges 5,096–6,487 frames against 6,144 modelled, so the two disagree by roughly
half a buffer to a buffer depending on where in the callback cadence the reading falls.

Which of the two is correct for the correction formula is **not yet established**. The formula
evaluates inside the callback, where the buffer just returned has been re-enqueued, and in-flight
there may genuinely be the full allocated depth. Two things need measuring before changing it:

1. In-flight sampled *at the callback instant*, not at an arbitrary one.
2. Whether `AudioQueueGetCurrentTime`'s `mSampleTime` reports the position the device has
   consumed or the position it is emitting. If the latter, it already carries the device path and
   adding `deviceLatency` double-counts it. `inFlight` readings above the modelled depth (6,487
   against 6,144) are weak evidence for the latter and are not conclusive.

Sizing buffers by duration rather than a fixed byte count would remove the format dependence in
this term at the same time — the depth currently doubles across a bit-depth change.

## Why the offset is still invisible in `sync`

`graceExpiryRebaselineCursor` **assigns** `cursor = expected + L` one second into playback. It does
not measure the equilibrium; it defines one, after which drift correction holds the system there
faithfully. The result is internally consistent, stable, and uniformly displaced — a single
speaker cannot reveal a constant displacement. `startOffset` exists solely to expose it, and any
change here that leaves the rebaseline asserting rather than measuring will hide the next error
the same way.

## Notes that remain true

- Scheduling the start instant precisely — via `AudioQueueStart`'s host-time parameter, honoured
  on macOS at leads as short as 5 ms — is unnecessary now that the device is pre-warmed and the
  first frame is placed by position rather than by start time.
- There is no `kAudioQueueProperty_CurrentDeviceLatency`. macOS answers through the HAL
  (`kAudioDevicePropertyLatency` + `SafetyOffset` + `BufferFrameSize` + stream latency on the
  default output device); the session platforms answer through `AVAudioSession.outputLatency`.
  The queue reports its device as `AQDefaultDevice`, so it follows the system default and the
  value must be re-read when that changes.
- `aiosendspin` ignores `required_lead_time_ms` entirely (`push_stream.py` uses a fixed
  `DEFAULT_INITIAL_DELAY_US = 250_000`), so deriving that value buys nothing against this server
  — though it remains spec-correct and matters for others.
- The DAC's own oversampling-filter delay may not be in the driver's reported figure. It is
  common-mode when syncing identical endpoints and only matters across dissimilar hardware.
