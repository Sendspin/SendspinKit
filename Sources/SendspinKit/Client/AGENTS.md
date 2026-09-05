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
- **Outbound sends:** the connection is the transport's single writer. Facade APIs
  (player/artwork state-preference setters and controller commands) route through connection
  methods that publish full `client/state` snapshots or send `client/command`. The facade stores no transport,
  channel, or CryptoKit reference. `HandshakeDriver` owns each candidate
  through raw init, Noise establishment, encrypted `server/hello`/`client/hello`, pairing setup,
  and the first admitted activation, then transfers the channel to the connection.
- **Expects:** a `SendspinTransport` (pull interface — `nextFrame()`, `sendRawText`,
  `sendBinary`, `disconnect`; single-consumer receive, returns nil on close) and a
  `ClockSyncProtocol`. There is no `send(Codable)` transport contract.

## Key Decisions
- **Lifetime = owned objects, not generation counters.** The old `connectionGeneration` machinery was
  replaced by: a supervisor task (`runLoop`), run-once teardown, an identity guard, and
  `SessionValidityToken`. Reconnect builds a *new* connection+engine+token; `shutdown()` invalidates
  the old token so its in-flight binary events are silently dropped.
- **Lifecycle events are render-applied, async.** `.streamStarted`/`.streamFormatChanged` derive from
  engine `EngineReport`s (`.started`/`.formatApplied`), so they are NOT wire-ordered against
  `.rawAudioChunk`. "No audio before stream/start" is enforced by the `playerStreamActive` gate at
  frame receipt, NOT by event ordering. Tests must assert within-class order + counts, not cross-class
  interleaving.
- **Seamless-format classification is synchronous.** `announcedPlayerFormat` (set at enqueue in
  handleStreamStart) keys `isFormatChange`; the public render-applied `currentStreamFormat` does not.
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
  code attempt, pairing window primitive, timeout/lifetime tasks, and pairing-activate counter. The
  app gesture uses the connection-owned window primitive; a re-handshake clears attempt state and
  resets the activate counter before the next activation.
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
- `SendspinClient+Commands.swift` — player/artwork state preferences and controller commands.
- `ConnectionEvent.swift` — control-plane event enum + `ConnectionLifecycle`.
- `SessionValidityToken.swift` — atomic check-and-yield guard for stale binary events.
- `PlayerConfiguration.swift` — adds `requiredLeadTimeMs` / `minBufferMs` (player role, `client/state` player object).
- `../Audio/{AudioEngine,DataPlaneCommand,DataPlaneSink}.swift` — the engine and its channel.

## Gotchas
- Do not add MainActor-observable production surface just to make a test observable — it violates the
  off-main goal. Assert via the engine command/report channels instead.
- A new stream can set `playerStreamActive=true` before a stale prior-stream report drains; the
  synchronous `announcedPlayerFormat` narrows this but a small residual window is known/accepted.
