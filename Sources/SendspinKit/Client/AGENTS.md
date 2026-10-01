# Client — Control/Data-Plane Split

## Purpose
Splits the protocol client into a thin UI-facing facade and an off-MainActor engine so all heavy
audio/control work runs off the MainActor, while `@Observable` state still updates on the MainActor
for SwiftUI.

## Architecture (the central invariant)
**One-way dependency: facade → connection → engine.**
- `SendspinClient` (`@MainActor @Observable final class`) — thin facade. Holds public API, observable
  state, and the public `events` stream. Owns nothing audio-related directly.
- `SendspinConnection` (`actor`) — owns the transport, the ordered message loop, protocol-intent
  gates, clock sync, and the `AudioEngine`. **Holds no `SendspinClient` reference and imports nothing
  `@MainActor`-isolated**. It is the single writer of session state.
- `AudioEngine` (`actor`, in `../Audio/`) — owns decode/schedule/output/sync-telemetry and the
  seamless-format state machine. No `@MainActor` / `MainActor.run` anywhere.

## Contracts
- **Control plane:** the connection emits `ConnectionEvent` on its control `AsyncStream`. The facade's
  `drainConnectionEvents()` consumes it on the MainActor, applies `@Observable` state, then re-emits
  the public `ClientEvent` (single public emission point). Terminal event: `.disconnected(reason:)`.
- **Data plane (binary):** audio/artwork/visualizer bytes bypass the facade and are yielded directly
  to the public continuation off-main via `SessionValidityToken.yieldIfValid(_:to:)`.
- **Facade → engine:** the message loop enqueues `DataPlaneCommand`s onto the engine's ordered
  `DataPlaneSink`; the engine emits `EngineReport`s, drained by the connection's `reportDrain()`
  into `ConnectionEvent`s. (Both enums are `internal`; tests use `@testable import`.)
- **Outbound sends:** the connection is the admitted transport's single writer; state preferences,
  availability, controller commands, group leave, pairing, clock sync, and goodbye use its FIFO slot.
  Pairing PSK `client/pair-init` and `client/pair-finalize` share one acquisition and remain adjacent.
  The facade stores no transport, channel, or CryptoKit reference; `HandshakeDriver` owns candidates
  through raw init, Noise establishment, encrypted hello, pairing setup, and activation admission,
  then transfers the channel to the connection.
- **Expects:** a `SendspinTransport` (pull interface — `nextFrame()`, `sendRawText`,
  `sendBinary`, `disconnect`; single-consumer receive, returns nil on close) and a
  `ClockSyncProtocol`. There is no `send(Codable)` transport contract.

## Key Decisions
- Binaries are dropped while the last successfully published `client/state` reports
  `available: false`, without disconnecting.
- **Activation admission:** long-term PSKs admit empty or playback activities; pairing PSKs and
  Sentinel also admit pairing and combined playback/pairing, with playback requiring unpaired access.
  Adding pairing does not quiesce playback; omitted roles persist subject to the session's rules.
- **Role removal:** versioned-role differences clear metadata/color/controller state and scheduled
  updates, stop player/artwork/visualizer output, and discard their buffers; unchanged roles retain state.
  Artwork end/removal/configuration changes invalidate pending image delivery and clear current artwork.
- **Re-handshake:** only keys change; roles, streams, buffers, clock filter, and unchanged artwork
  transfers persist, neither hello repeats, and only `server/activate` is admitted under new keys first.
- **Lifetime = owned objects.** A supervisor task (`runLoop`), run-once teardown, an identity guard,
  and `SessionValidityToken` govern ownership; reconnect builds a new connection, engine, and token.
  `shutdown()` invalidates the retired token so its in-flight binary events are silently dropped.
  `AdvertisingTransportOwnership` is passed through internal acceptance, arbitration, and setup;
  the claim remains authoritative after admission returns, and `AdvertisingCandidateTransport` routes
  pre-adoption cleanup through it; adoption removes the pending candidate and installs its original transport.
- **Lifecycle events are render-applied, async.** `.streamStarted`/`.streamFormatChanged` derive from
  engine `EngineReport`s (`.started`/`.formatApplied`), so they are NOT wire-ordered against
  `.rawAudioChunk`. "No audio before stream/start" is enforced by the `playerStreamActive` gate at
  frame receipt, NOT by event ordering. Tests must assert within-class order + counts, not cross-class
  interleaving.
- **Stream classification uses wire identity.** `announcedPlayerStream` stores format and codec header
  in `handleStreamStart`; identical active announcements preserve the timeline, changed configurations
  preserve buffered audio, and failed starts retry; render-applied `currentStreamFormat` is not the key.
- **Start identity guards sibling tasks.** Engine start/format reports carry the start generation;
  the connection applies only the report matching its pending generation because the message loop
  and report drain are sibling tasks.
- **`EngineReport.operationalState` carries the full target state** (bidirectional in/out of
  `.error`/`.synchronized`) — a one-way edge would break the single-writer claim.
- **Stream-active mirrors are observational.** The facade's
  `playerStreamActive`/`artworkStreamActive` are render-applied observability mirrors that gate
  nothing. State preference publication is valid even when no stream is active; the server applies the
  preference to the next stream and does not start one in response. `stream/clear` clears buffers
  WITHOUT ending the stream (spec): mirrors and format survive it on both sides.
- **Pairing configuration has one runtime source of truth.** `PairingConfigurationRuntime` supplies
  the snapshot shared by handshake candidates and active sessions; updates do not rely on
  stale copies held by individual connections.
- **Pairing state is connection-owned and serialized.** `SendspinConnection` holds the single active
  attempt, connection-scoped pairing window and failed-confirmation count, timeout/lifetime tasks,
  pairing-activate counter, and client-abort discard state. Only a client-sent abort opens the
  discard interval. Window identity cancellation closes authorization even without an active attempt.
  Activations emit `pairingAttemptSuperseded` and replace attempt state without consuming the window
  or resetting the device-wide budget; the next activation ends the discard interval.
  `openPairingWindow` resets the emitted-round budget, including an already-open window.
  Success, five failed static confirmations, cancellation, expiry, or disconnect closes the window;
  re-handshake clears attempt state and resets the activate counter without clearing connection state.
- **The encoder has no key strategy.** Every outbound `Codable` model declares explicit `CodingKeys`,
  including keys whose wire spelling differs from Swift naming; never rely on encoder key-strategy
  configuration for protocol output.
- **The `currentArtwork` MainActor observer honors `SessionValidityToken`** just like the public
  binary yields — a retired connection's in-flight artwork must not mutate facade state.

## Invariants
- The connection never references the facade or any `@MainActor` type (one-way dependency).
- Exactly one public emission of each event (facade re-emits control; data plane emits binary).
- Permanent engine shutdown must call `audioScheduler.finish()` (not just `stop()`), else the
  scheduler output task hangs forever on `for await`.

## Key Files
- `SendspinClient.swift` — MainActor facade; connection lifecycle, observable state, events, and state-preference APIs.
- `HandshakeDriver.swift` — candidate Noise establishment, pairing setup, encrypted hello/activate admission, channel handoff.
- `SendspinConnection.swift` — encrypted message loop, state snapshots, gates, supervisor, `reportDrain`, binary emission.
- `SendspinClient+Commands.swift` — player/artwork/visualizer preferences, availability, pairing, group leave, and controller commands.
- `SendspinConnection+Outbound.swift` — FIFO encrypted sends, adjacent PSK pair, and controller validation.
- `SendspinConnection+MessageHandling.swift` — activation cleanup, re-handshake, pairing lifecycle, and stream configuration.
- `SendspinConnection+RequestFormat.swift` — output-route negotiation, preference snapshots, and fallback status.
- `ActivationAdmissibility.swift` / `SendspinPersistenceProvider.swift` — activity admission and shared pairing policy runtime.
- `SendspinConnection.artworkDeliveryValidity` — `SessionValidityToken` for pending artwork delivery invalidation.
- `../../../Tests/SendspinKitTests/Client/PlayerStreamConfigurationTests.swift` — active-stream identity and retry coverage.
- `ConnectionEvent.swift` — control-plane event enum + `ConnectionLifecycle`.
- `SessionValidityToken.swift` — atomic check-and-yield guard for stale binary events.
- `PlayerConfiguration.swift` — adds `requiredLeadTimeMs` / `minBufferMs` (player role, `client/state` player object).
- `../Audio/{AudioEngine,DataPlaneCommand,DataPlaneSink}.swift` — the engine and its channel.

## Gotchas
- Do not add MainActor-observable production surface just to make a test observable — it violates the
  off-main goal. Assert via the engine command/report channels instead.
- A new stream can set `playerStreamActive=true` before a stale prior-stream report drains;
  start/format reports require the matching pending start generation, not the stream-active flag.
