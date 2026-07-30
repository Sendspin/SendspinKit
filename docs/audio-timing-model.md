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

## Unresolved: intermittent silence, currently not reproducing

On one machine (MacBook, built-in speakers) some runs produce no sound while every counter reads
healthy. In those runs `AudioQueueStart` blocks for 13.21-13.29s -- eight readings inside 80ms of
each other, which is a timeout rather than a wake -- and the chunk backlog then arrives in a
single burst, because `prepare()` runs on the engine's ordered command loop.

A stack sample taken during the block shows where:

```
AudioQueueStart -> AudioQueueXPC_Bridge::Start -> AudioQueueObject::StartRunning
  -> AQMEIO_Base::StartIO_Sync -> AudioDeviceStart_mac_imp
    -> HALC_ProxyIOContext::_StartIO(StartIO_RetryMethod)     <- loops
      -> HALB_IOThread::StartAndWaitForState -> HALB_Guard::WaitFor
        -> _pthread_cond_wait -> __psynch_mutexwait           <- 11,295 of 11,399 samples
```

The IO thread it waits on sits in `mach_msg` inside `IOWorkLoop` and never reaches its running
state; `_StartIO` retries for 13.2s until CoreAudio brings up a replacement IO thread, which then
does render. Neither IO thread carries a SendspinKit frame, so this is not a lock this client
holds and not its render callback.

After the stall the pipeline is indistinguishable from a working one: frames consumed at exactly
the device clock (92,160 per 2.09s = 44,100/s), `peak=0.2121`, `silentBufs=0`, `enqFail=0`,
`underrun=0`, sync within 83us and not correcting -- and still inaudible.

Eliminated by measurement. Do not revisit without new evidence:

- **Writing silence.** `peak` on a silent run equals `peak` on an audible one.
- **Device selection.** Built-in speakers, not Bluetooth, virtual or aggregate.
- **Sample-rate mismatch.** 13,220,152us at 48kHz against 13,222,207us at 44.1kHz.
- **The pty wrapper.** Under `script` 238-255ms, direct 337-347ms; neither near 13s.
- **A slow DAC.** Same machine and device, 233ms on a run that worked.
- **A refused enqueue.** `enqFail=0` on a silent run, the failure mode recorded in b8c4ddc.
- **Gain.** `gain=1.00 qGain=1.00 devMute=false`, the queue parameter read back rather than
  assumed.

**It is timing-sensitive and currently will not reproduce.** Two separate telemetry-only commits
have each coincided with it disappearing -- a9ba372 and the batch ending aab0688 -- and telemetry
cannot fix anything, so both are perturbation rather than repair. It has also been seen to vanish
and return within minutes with no change at all. Any run that works proves nothing on its own.

What remains actionable regardless of the cause:

1. `prepare()` blocks the engine's ordered command loop for the whole of `AudioQueueStart` --
   339ms on a healthy machine, and everything piles up behind it. Starting the queue without
   blocking the loop would turn this fault from catastrophic into a late start, since
   `outputDeviceIsLive` already gates the release.
2. A start slower than `audioQueueStartSlowThresholdUs` is logged at `.notice`, so a
   user-collected log shows it without debug logging.
3. The smoke harness fails on spin-up over 2s, on a peak that never rises, and on any refused
   enqueue.

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
