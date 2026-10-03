# Audio timing model

How a server timestamp becomes a sample at the speaker, what the playback cursor means, and
where the current implementation departs from the model. Each measurement section identifies
its hardware; startup-offset reference figures use a Mac Studio and USB DAC, while callback-depth
and measured-correction figures use a MacBook Air's built-in speakers.

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

- The correction target is one shared mapping: `snapshot.localTimeToServer(localNow + physicalPipeline + localOutputDelay)`, with saturating local arithmetic. The callback error, grace-expiry rebaseline, and reanchor target all use that exact helper, including nonzero clock drift.
- `L` includes the device path, read from the HAL at `prepare()` (`OutputDeviceLatency`), while the commanded output delay remains a separate local-domain term.
- A runtime output-delay change shifts every pending scheduler/startup/deferred local play instant by `oldDelay - newDelay` exactly once. Wire timestamps and decoded cadence remain unchanged; chunks already yielded to the output are immutable and are corrected by render pacing rather than rewriting PCM.
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

## Measured start offset

Each row is the offset playback actually starts at on the Mac Studio/USB DAC reference setup,
with 44.1kHz/stereo/32-bit output.

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

**The device itself wakes in roughly 50 ms.** The remaining 300-400 ms is dominated by this
call, because `spinUp` is stamped before it. Pre-warming moves this cost off the release path.

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

The following checks did not identify the cause:

- **Writing silence.** `peak` on a silent run equals `peak` on an audible one.
- **Device selection.** Built-in speakers, not Bluetooth, virtual or aggregate.
- **Sample-rate mismatch.** 13,220,152us at 48kHz against 13,222,207us at 44.1kHz.
- **The pty wrapper.** Under `script` 238-255ms, direct 337-347ms; neither near 13s.
- **A slow DAC.** Same machine and device, 233ms on a run that worked.
- **A refused enqueue.** `enqFail=0` on a silent run.
- **Gain.** `gain=1.00 qGain=1.00 devMute=false`, the queue parameter read back rather than assumed.

The failure remains timing-sensitive and was not reproduced by the available runs. Telemetry-only
changes altered the outcome but cannot account for a repair, so the cause remains open.

What remains actionable regardless of the cause:

1. `prepare()` blocks the engine's ordered command loop for the whole of `AudioQueueStart` --
   339ms on a healthy machine, and everything piles up behind it. Starting the queue without
   blocking the loop would turn this fault from catastrophic into a late start, since
   `outputDeviceIsLive` already gates the release.
2. A start slower than `audioQueueStartSlowThresholdUs` is logged at `.notice`, so a
   user-collected log shows it without debug logging.
3. The smoke harness fails on spin-up over 2s, on a peak that never rises, and on any refused
   enqueue.

## Measured depth at the correction instant

Placement and correction describe the same physical span: frames enqueued but not yet consumed,
plus the device path. Correction samples that depth before its fill loop, while the cursor still
names the previous callback's tail. The same sample feeds sync error, grace-expiry rebaseline and
reanchor targets. Before the first positive device position, the allocated-depth model stands in;
once a position is observed for the queue, a missed or zero read holds its previous measured depth.
Only successful enqueues enter the cumulative frame count; refused and withheld buffers do not.
Startup leads and silence-pad ceilings remain conservative allocated-depth estimates.

Three 30-second tone runs on a MacBook Air's built-in speakers use 44,100Hz/stereo/32-bit output:
16,384 bytes per buffer / 8 bytes per frame = 2,048 frames; three buffers model 6,144 frames.
Callback depth spans 4,622–5,090 frames (2.26–2.49 buffers), leaving a 1,054–1,522-frame model gap.
The interval-last medians are 4,801.5 / 4,932.5 / 4,926 frames. The delivery-delay formula clamps to
zero: measured depth exceeds two buffers rather than simply being two minus callback delay.
The first callbacks report 1,357 / 1,356–1,361 / 1,356–1,357 consumed frames for a 2,048-frame buffer;
a queue-to-device internal stage remains in flight and only measured depth captures it.

The queue timestamp's host time maps through `AudioQueueDeviceTranslateTime` to the current device
position within 0–1 frame; host lag spans 0.21–1.04 µs and every API status is successful.
Queue and device sample origins differ, so translation uses the queue timestamp's host-time
component. This establishes a current consumption reference, not an already audible position;
the device latency remains additional. Timestamp evidence does not measure analog speaker delay.
The callback timestamp read costs at most 11 µs against a 46.44 ms buffer period.

With measured depth in correction, three further 30-second runs show:

| run | modelled startOffset | measured startOffset | modelled steady sync | measured steady sync |
|---|---|---|---|---|
| 1 | 34,776 µs | 116 µs | −2,956…+4,874 µs | −173…−36 µs |
| 2 | 29,821 µs | 17,198 µs | −4,624…+3,290 µs | −51…−12 µs |
| 3 | 32,890 µs | 5,185 µs | −4,034…+3,278 µs | −55…+23 µs |

The modelled runs alternate drop/insert mode 4 / 3 / 4 times at telemetry cadence; measured-depth
runs report no correction, drop or insert cadence. All runs report zero late chunks, underruns,
PCM drops and enqueue failures. Run 2 includes a queue restart; its residual 17.20 ms is real
placement error at grace expiry, not evidence that all startup placement is accurate to a few ms.
Sizing buffers by duration rather than a fixed byte count remains separate from correction.

## Why the offset is still invisible in `sync`

`graceExpiryRebaselineCursor` **assigns** `cursor = expected + L` one second into playback.
Measured device depth makes `L` a physical estimate rather than an allocated-buffer model;
`startupOffsetUs` now measures placement error at grace expiry. The rebaseline still absorbs that
error into the cursor, so subsequent `sync` cannot expose a constant startup displacement.
`startOffset` remains necessary even when steady-state sync is quiet: the 17,198 µs placement
residual above becomes invisible after the rebaseline. `startLate` reports how late the first frame
is when a negative silence-pad gap clamps to zero; it is zero when no late clamp occurs.

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
