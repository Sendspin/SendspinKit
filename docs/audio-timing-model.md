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

## Departure 1 — the latency term has the wrong sign

`AudioPlayer.updateCorrectionSchedule` computes

```
syncError = (expected − cursor) − L
          = [(expected + L) − cursor] − 2L
          = error_true − 2L
```

Subtracting `L` where the invariant adds it. The consequence is not a constant offset that can be
tuned away: **any change to `L` moves the equilibrium by `2·ΔL`**. Adding a measured 14.7ms device
term to both the engine's scheduling and this formula moved the observed equilibrium by 27.6ms.

Measured at the first evaluation of a stream, where the invariant holds exactly:

| | value |
|---|---|
| `cursorLead` | +154,004 µs |
| `L` (`aqLatency`) | 154,035 µs |
| `syncError` as computed | −308,039 µs |
| `syncError` with the sign corrected | **+31 µs** |

With the sign corrected the engine's scheduling and the correction model agree to 31
microseconds. They were never two competing models.

## Departure 2 — device spin-up is not modelled

Between `AudioQueueStart` and the first output callback:

| | |
|---|---|
| predicted from buffer depth | ~32 ms |
| measured, run 1 | 299,192 µs |
| measured, run 2 | 396,424 µs |

An idle USB DAC takes 300–400ms to begin producing, and the figure varies by ~100ms between
runs. Nothing in the scheduling accounts for it, so playback begins that much late and the whole
cursor relationship is displaced:

```
cursorLead(steady) = +L − spinUp = 154,035 − 300,905 = −146,870 µs
```

against −146,870 µs measured. This term dominates every other latency in the system, including
the queue depth (139ms) and the device latency (15ms).

## Why neither departure is audible today

`graceExpiryRebaselineCursor` **assigns** `cursor = expected − L` one second into playback. It does
not measure the equilibrium; it defines the wrong one into existence, after which drift correction
holds the system there faithfully. The result is internally consistent, stable, and uniformly
displaced.

A single speaker cannot reveal a constant displacement. Two speakers with differing pipeline
depth — different format, device, or buffer size — reveal it as fixed misalignment, scaling with
`2L` rather than `L`.

## Departure 3 — the device path is modelled as zero

`L` currently counts only the AudioQueue buffers this client primes. The path beyond them is real
and measurable (`OutputDeviceLatency`): on the reference setup, 14.7ms — device latency 1.5ms,
safety offset 1.6ms, IO buffer 11.6ms. An independent estimate from output-callback timing put it
at ~17.5ms, corroborating within 3ms.

There is no `kAudioQueueProperty_CurrentDeviceLatency`. macOS answers through the HAL
(`kAudioDevicePropertyLatency` + `SafetyOffset` + `BufferFrameSize` + stream latency on the
default output device); the session platforms answer through `AVAudioSession.outputLatency`. The
queue reports its device as `AQDefaultDevice`, meaning it follows the system default — so the
value must be re-read when the default output device changes.

## Consequences for a fix

1. The sign correction and the spin-up term must land together. Fixing the sign alone gives a
   correct startup and a wrong steady state, because the anchor re-seats the cursor after the
   pre-fill and the spin-up displacement remains.
2. Scheduling the start instant precisely — via `AudioQueueStart`'s host-time parameter, which is
   honoured on macOS at leads as short as 5ms — buys nothing while a 300ms spin-up sits
   downstream of it, unmeasured.
3. `graceExpiryRebaselineCursor` must stop defining the equilibrium. Any fix that leaves it
   asserting a relationship rather than measuring one will hide the next error the same way.
4. `aiosendspin` ignores `required_lead_time_ms` entirely (`push_stream.py` uses a fixed
   `DEFAULT_INITIAL_DELAY_US = 250_000`), so deriving that value buys nothing against this server
   — though it remains spec-correct and matters for others.
