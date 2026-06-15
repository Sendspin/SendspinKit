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
  (`requestPlayerFormat`, `requestArtworkFormat`, controller commands) route through connection
  methods (`requestFormat(player:)`/`requestFormat(artwork:)`/`send(clientMessage:)`). The facade
  stores NO transport reference at all (structural guarantee, not convention); its only transport
  write is `performHandshake` on a candidate transport during multi-server arbitration, before a
  connection exists for it.
- **Expects:** a `SendspinTransport` (pull interface — `nextFrame()`, single-consumer, returns nil on
  close) and a `ClockSyncProtocol`.

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
- **Protocol-intent gates are connection-authoritative.** The facade's
  `playerStreamActive`/`artworkStreamActive` are render-applied observability mirrors that gate
  nothing. `stream/clear` clears buffers WITHOUT ending the stream (spec): gates and format survive
  it on both sides.
- **The `currentArtwork` MainActor observer honors `SessionValidityToken`** just like the public
  binary yields — a retired connection's in-flight artwork must not mutate facade state.

## Invariants
- The connection never references the facade or any `@MainActor` type (one-way dependency).
- Exactly one public emission of each event (facade re-emits control; data plane emits binary).
- Permanent engine shutdown must call `audioScheduler.finish()` (not just `stop()`), else the
  scheduler output task hangs forever on `for await`.

## Key Files
- `SendspinClient.swift` — facade; `connect`/`disconnect`, `drainConnectionEvents`, state setters.
- `SendspinConnection.swift` — message loop, gates, supervisor, `reportDrain`, binary emission.
- `ConnectionEvent.swift` — control-plane event enum + `ConnectionLifecycle`.
- `SessionValidityToken.swift` — atomic check-and-yield guard for stale binary events.
- `PlayerConfiguration.swift` — adds `requiredLeadTimeMs` (spec §485) / `minBufferMs` (§486).
- `../Audio/{AudioEngine,DataPlaneCommand,DataPlaneSink}.swift` — the engine and its channel.

## Gotchas
- Do not add MainActor-observable production surface just to make a test observable — it violates the
  off-main goal. Assert via the engine command/report channels instead.
- A new stream can set `playerStreamActive=true` before a stale prior-stream report drains; the
  synchronous `announcedPlayerFormat` narrows this but a small residual window is known/accepted.
