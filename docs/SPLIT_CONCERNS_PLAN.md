# Split the Control Plane from the Data Plane Design

<!-- slug: control-data-plane-split -->

## Summary

SendspinKit today processes audio chunks, decoding, scheduling, and sync correction all through `SendspinClient`, a `@MainActor @Observable` class. That means every audio frame — potentially hundreds per second — hops onto the main thread, creating contention with UI rendering and making the data path structurally dependent on a UI isolation domain it has no business touching. This refactor separates those two concerns at the architecture level: a new `AudioEngine` actor owns the entire data plane (decode → schedule → output → sync correction), a new `SendspinConnection` actor owns one physical socket and its protocol state machine, and `SendspinClient` is demoted to a thin observable facade that owns nothing real except a reference to the current connection.

The approach works outward from a stable baseline: Phase 1 locks spec-correct behavior in characterization tests before anything moves; Phase 2 converts the transport from a push `AsyncStream` to a `nextFrame()` pull surface, which eliminates a fragile resume-cancelled-iteration workaround used in multi-server arbitration; Phase 3 replaces the third-party Starscream WebSocket library with the native Network.framework transport already present for the inbound (server-accept) path; Phase 4 extracts the data plane into `AudioEngine`, moving audio work off the MainActor; Phase 5 promotes the routing into a `SendspinConnection` actor whose **one-way dependency** (it holds no facade reference) is the compile-time proof that the frame path cannot touch the MainActor, replaces the scattered `connectionGeneration` re-check-after-await pattern with a single owned-object lifetime (one `shutdown()` root, plus a two-path identity guard — `===` for control events, a `Sendable` validity token for off-main binary), and wires the render-applied event contract through the facade. Phase 6 collapses the now-thin extension files. Two conformance checkpoints — at Phase 3 and Phase 5 — run the cross-implementation audio-hash suite to gate interop correctness at the moments most likely to break it.

## Architecture

### Governing principle

> Separate the control plane from the data plane. Only the control plane touches the MainActor.

- **Control plane** — low-frequency, UI-relevant: `connectionState`, volume, mute, metadata, group, controller state, lifecycle events. Naturally `@MainActor @Observable`; a few actor→MainActor hops per second is fine.
- **Data plane** — high-frequency, real-time: audio chunks, decode, scheduling, AudioQueue, sync correction. Never touches the MainActor. Routed actor-to-actor.

### Components, isolation domains, contracts

Three components, three isolation domains, one dependency direction (facade → connection → engine). Contracts (shapes, not bodies):

```swift
// DATA PLANE — actor, never touches MainActor
actor AudioEngine {
    init(clock: ClockSynchronizer)
    nonisolated var commands: DataPlaneSink { get }            // ordered ingress; wraps a continuation +
                                                               // an explicit depth counter (watermark)
    nonisolated var reports: AsyncStream<EngineReport> { get }  // ordered egress; a stream, not a stored
                                                               // closure, to avoid a connection→engine→
                                                               // closure→connection retain cycle
    func start()            // idempotent; spawns the owned drain task (internal runLoop, drains `commands`)
    func shutdown() async   // stop AudioPlayer/output, finish commands + reports, await the drain task
    func setGain(_ gain: Float) async    // command-path control (not wire-ordered vs audio)
    func setMuted(_ muted: Bool) async   // command-path control
}
enum DataPlaneCommand { case streamStart(AudioFormatSpec), chunk(Data, ts: Int64),
                             streamClear, streamEnd, formatChange(AudioFormatSpec), setStaticDelay(Int) }
enum EngineReport { case started(AudioFormatSpec), formatApplied(AudioFormatSpec), underrun, error(Error) }

// PROTOCOL CORE — one per physical socket
actor SendspinConnection {
    init(transport: SendspinTransport, parsedHello: ServerHelloMessage?)
    func start()                             // idempotent; spawns the owned SUPERVISOR task:
                                             //   await runLoop(); await finishTeardown(reason)
                                             // runLoop = withTaskGroup { messageLoop; clockSyncLoop;
                                             // drain(engine.reports) }. lifecycle idle→running.
    nonisolated var events: AsyncStream<ConnectionEvent> { get }   // CONTROL plane; terminates with .disconnected
    func send(_ command: ClientCommand) async throws
    func disconnect(reason: GoodbyeReason) async  // graceful: sends ONE client/goodbye, then closes
    func shutdown() async                         // hard: no goodbye (dealloc / forced replace / losing probe)
    // All teardown — graceful, hard, or unsolicited remote close — converges on the supervisor's
    // finishTeardown (runs once, emits exactly one .disconnected). See "Connection lifetime & teardown".
}

// TRANSPORT — Network.framework, both directions
protocol SendspinTransport: Actor, Sendable {
    // SINGLE-CONSUMER: at most one in-flight nextFrame() at a time. Overlapping calls are a contract
    // violation; the handshake→message-loop handoff transfers read ownership with no overlap.
    func nextFrame() async -> TransportFrame?   // nil on close; backed by an internal single-reader buffer
    var isConnected: Bool { get }
    func send(_ message: some Codable & Sendable) async throws
    func sendBinary(_ data: Data) async throws
    func disconnect() async                      // cancels NWConnection AND finishes the buffer
}
```

### The two-producer event seam

Binary data events and control events reach the public `events` stream by **two different paths**:

- **Binary** (`rawAudioChunk` / `visualizerData` / `artworkReceived`) — yielded to the public stream from the connection's message loop, in wire order, off-MainActor. The yield targets a `Sendable` continuation and is gated by a `Sendable` **session-validity token** (see below); it never transits the facade.
- **Control + render-applied lifecycle** — flow `connection.events` → facade, which applies `@Observable` state *then* re-emits (state-before-event preserved).

`SendspinClient` (the `@MainActor @Observable` facade) owns `var connection: SendspinConnection?`, drains its control events, and merges them with the connection's binary events into the one public `events` stream the host sees.

**No-MainActor-hop is proven by the dependency direction.** The dependency is one-way: the facade holds the connection; `SendspinConnection` holds **no `SendspinClient` (no `@MainActor`) reference**. The message loop therefore *cannot* reach MainActor state — there is nothing MainActor-isolated in scope. It freely touches connection-actor-isolated state (the protocol-intent gates) because that is its own isolation domain, routes audio to the `Sendable` `DataPlaneSink`, delivers `server/time` to the `ClockSynchronizer` actor, and yields binary to the public continuation.

**Binary identity gating (the off-main half of the identity guard).** Because binary events bypass the facade, the facade's `=== ` guard cannot cover them. A retired connection's loop can still be mid-flight when its replacement is installed (between synchronous retire and the completion of `await shutdown()`), and would otherwise leak stale `rawAudioChunk`/artwork/visualizer into the public stream. The connection therefore holds a `Sendable` validity token (an atomic flag / `OSAllocatedUnfairLock`-guarded bool); the facade flips it to invalid **synchronously at retire**, before awaiting `shutdown()`; the binary yield checks it and drops if invalid. This is *not* the old `connectionGeneration` machinery (a per-`await` integer re-checked at N sites) — it is a single flag checked on one path, the binary counterpart to the control-plane identity guard.

**Consequence (accepted):** order is preserved *within* each class (binary events wire-ordered among themselves; control/lifecycle events ordered among themselves), but the *interleaving between the two classes* is non-deterministic. Nothing consumes cross-class order, and the interop-relevant *processing* order is held by the ordered data-plane channel regardless. The escape hatch, if a consumer ever needs cross-class ordering, is **Alt C** (two separate public streams) — see Additional Considerations.

#### Alternatives considered and rejected

- **Funnel binary through the facade (one ordered stream).** Reintroduces the per-chunk MainActor hop this entire refactor removes. Rejected.
- **One producer at the connection actor.** No MainActor hop, but adds a per-chunk actor hop and serializes binary behind control processing, re-coupling the planes. Rejected.
- **One stream + a sequencer that buffers binary behind lifecycle** to emit true wire order. Reintroduces the coordination point that gates the data plane on render-applied lifecycle, adding latency for an ordering nobody consumes. Rejected.

### Command path (control-plane writes, applied synchronously)

The facade is a thin projector for *server-driven* state, but **command APIs are not pass-through** — they must preserve today's synchronous optimistic-write semantics (`SendspinClient.swift:739`). `setVolume`/`setMute`/`setStaticDelay` update their `@Observable` property *before returning* and notify the server best-effort, so a caller (or SwiftUI binding) reading `client.currentVolume` immediately after `await setVolume(_:)` sees the new value. The split must not regress this into "write locally, then wait for a server echo via the event drain."

- The **facade validates availability first, then mutates.** As today (`guard let audioPlayer else { throw .notConnected }` *before* the write), a command on a disconnected client throws `.notConnected` **without** changing observable state. On the success path it applies the observable write synchronously on the MainActor (`currentVolume` / `currentMuted` / `staticDelayMs`), then forwards to the connection. It does **not** await a server confirmation to update local state.
- The connection applies the effect off-main: gain/mute via `engine.setGain` / `engine.setMuted` (direct, *not* wire-ordered against audio); `setStaticDelay` via the ordered `DataPlaneSink` (it shifts the scheduling timeline) and on the wire as `client/state`. (Today `setVolume` also called `audioPlayer.setVolume` directly; the player now lives in the engine, so that call routes there.)
- Server-originated changes (`staticDelayChanged`, a server-driven volume/mute echo) still arrive via the event path and reconcile the same observable state — last writer wins, as today.

### Connection lifetime & teardown

A connection is an **owned object with one lifetime boundary**, replacing the `connectionGeneration` integer + scattered re-check-after-await guards. Four explicit mechanisms — chosen deliberately over "just use task cancellation," which fails here because the facade holds the connection as a long-lived, *replaceable* stored property (not inside a lexical scope), and because closing the socket / stopping `AudioPlayer` / `finish()`-ing channels are async operations that cannot run in a synchronous `onCancel` or a non-async `deinit`:

1. **Lifecycle state machine** — `idle → running → shuttingDown → stopped`, an actor-isolated property; every transition is set *before the first suspension*, so the check-and-set is atomic on the actor. `start()` transitions `idle → running` (idempotent: a second call while `running` is a no-op). Any teardown trigger transitions `running → shuttingDown`; the actual teardown is the supervisor's single `finishTeardown` (mechanism 2), which runs exactly once however many callers race (mechanism 4). This is the real race the design must survive — stronger than calling `shutdown()` twice in sequence.
2. **A supervisor task owns run *and* teardown.** `start()` (idempotent) spawns and stores one owned task — the **supervisor**: `await runLoop(); await finishTeardown(reason)`. `runLoop()` drives the child loops (message loop + clock-sync loop + an `engine.reports` drain) under `withTaskGroup`. **`withTaskGroup` does *not* auto-terminate siblings when one child returns** — it waits for all. So `runLoop()` awaits `group.next()` (the first child to finish — normally the message loop, when the transport closes) then `group.cancelAll()`; the clock-sync loop is cancellation-cooperative (`Task.sleep` throws on cancel) and exits, letting the group drain. The supervisor then runs `finishTeardown` **whenever `runLoop()` returns, for *any* reason** — so an unsolicited remote close gets the identical teardown an explicit disconnect does. `finishTeardown(reason)` runs once (lifecycle-guarded): invalidate the binary validity token → `audioEngine.shutdown()` (stop `AudioPlayer`/output, finish `commands`+`reports`) → emit exactly one terminal `.disconnected(reason)` on the control stream → `finish()` the control stream → `stopped`. Because teardown runs only *after* `runLoop()` has returned (both loops stopped), a frame already returned by `nextFrame()` can never reach a finished engine channel.
3. **Three teardown triggers, one path, one `.disconnected`** (this is what preserves today's automatic loss cleanup *and* the explicit-goodbye path):
   - **Unsolicited close** (remote close / transport error): `nextFrame()` returns `nil` → `runLoop()` returns → supervisor tears down with `reason = .connectionLost`. **No `client/goodbye`** — the socket is already gone. (This is the `ConnectionLostTeardownTests` path: resources released, `.disconnected` emitted, a later command throws `.notConnected`, with no explicit call.)
   - **Graceful `disconnect(reason: GoodbyeReason)`**: record the reason and set `shuttingDown` *before the first `await`* (so it wins a race with a concurrent loss), send **exactly one** `client/goodbye(reason)` best-effort, then `transport.disconnect()` → `runLoop()` returns → supervisor tears down reporting that reason.
   - **Hard `shutdown()`**: no goodbye (dealloc, forced replace, losing multi-server probe). Set `shuttingDown`, invalidate the token, `transport.disconnect()`, `await` the supervisor task.
4. **Concurrent-safe via the lifecycle state.** Whoever sets `shuttingDown` + the reason first (before its first suspension) wins; a second caller — or `disconnect()` racing a connection loss racing `reconnect()` — observes `shuttingDown`/`stopped` and `await`s the **same** supervisor task. Net: **exactly one `client/goodbye` (graceful path only) and exactly one `.disconnected`.**
5. **Always-on identity guard, covering both event paths.** Control events are checked at the facade (`guard source === connection else { return }`); binary events are checked off-main against the `Sendable` validity token. Cancelling the event-consumer task is an *optimization*, never the correctness mechanism — an event may already be dequeued mid-flight.

The facade, observing the terminal `.disconnected`, retires its `connection` reference (releasing the transport + tasks the connection owns) and applies its reconnect policy — so unsolicited loss produces the same facade-level cleanup the old `teardownLiveConnection` did.

**Reconnect** = synchronously, on the MainActor: invalidate the old connection's validity token *and* null/replace `self.connection` (so both guards reject the dying connection's late events *during* teardown), then `await oldConnection.shutdown()` (hard; or `disconnect(reason: .restart)` to notify the server), then construct, install, and `start()` the new one.

**Multi-server promotion** rides the pull handoff: a probe handshakes by pulling frames until `server/hello`, then **waits** — emits no events, no audio, no clock-sync, no `client/state` — until the facade promotes it by handing its transport (mid-stream) + the parsed `ServerHelloMessage` to a real `SendspinConnection`. Losing probes are `shutdown()`.

### Data-plane routing, ordering, and gates

The connection's **message loop** is the one ordered reader (isolated to `SendspinConnection`, holding no facade reference — §"The two-producer event seam"). It pulls `nextFrame()`, classifies, and routes each frame to exactly one destination, never hopping to the MainActor:

- **Audio + barriers** (`stream/start`, chunk, `stream/clear`, `stream/end`, format-change, `set_static_delay`) → `engine.commands` (the ordered `Sendable` `DataPlaneSink`). Chunks and barriers share one queue, so **processing order holds by construction** — `stream/end` acts only after the chunks sent before it. This is the interop invariant the conformance audio-hash suite guards. Decode runs engine-side, so the loop never blocks on it.
- **`server/time`** → `ClockSynchronizer`, delivered **in order via an inline `await`** (low frequency, so blocking the loop briefly is fine), with `clientReceived` stamped at frame-read time. **Every sample is delivered — none dropped, coalesced, or reordered** (the filter accumulates samples and needs several to converge). The clock is updated *directly on the `ClockSynchronizer` actor*, not routed through the `DataPlaneSink` and not via a fire-and-forget task. `AudioScheduler` reads the actor when scheduling, unchanged.
- **Pure control frames** → `connection.events` (control projection); the loop also updates the connection-isolated protocol-intent gates here (its own isolation domain).
- **Binary data** → public stream, off-main, wire order, gated by the session-validity token.

**Diagnostic high-watermark.** The channel stays unbounded (a frame-count cap is protocol-incoherent — it would false-disconnect a compliant server using many small frames). A bare `AsyncStream.Continuation` exposes no queue depth, so `DataPlaneSink` is a thin wrapper that maintains an **explicit depth counter**: `enqueue` increments and `yield`s, the engine's drain decrements after dequeuing. When depth crosses the high watermark the engine logs a **rate-limited** warning (one per excursion, no disconnect). A rejected `yield` (continuation already finished, e.g. mid-shutdown) does not increment; `finish()` is terminal and stops accounting. Pure observability — the byte-accurate bound stays deferred.

**Two gates, deliberately distinct** (today's single `playerStreamActive` blurs them):

- **Protocol-intent gate** — set on the connection at *frame receipt* in the ordered loop (reflects what the server declared; gates `stream/request-format` legality). Eager. Because the loop is ordered, `stream/start` is dequeued before the chunks behind it, so the gate is open in time for compliant traffic.
- **Render-applied state** (`currentStreamFormat`, lifecycle events) — derived from the engine's upward `EngineReport`. What is *actually playing*.

**Pre-stream binary** is gated on all three roles' active streams (adding `visualizerStreamActive`), logged-and-discarded, never disconnecting. The auto-start shim is deleted.

## Existing Patterns

This design re-parents existing machinery; it rewrites very little.

- **Actors for off-main work already exist.** `AudioPlayer`, `AudioScheduler` (`Sources/SendspinKit/Audio/`), and `ClockSynchronizer` (`Sources/SendspinKit/Synchronization/ClockSynchronizer.swift`) are already actors. `AudioEngine` re-parents them; `AudioScheduler`/decoders need **no internal changes** (`AudioScheduler` already reads the clock via `await clockSync.serverTimeToLocal(...)`).
- **Transport protocol already exists** (`Sources/SendspinKit/Transport/SendspinTransport.swift`). The change swaps its push `frames` member for `nextFrame()` and unifies the two conformers onto one.
- **`NWWebSocketTransport` already uses the correct receive-loop pattern** (`Sources/SendspinKit/Transport/NWWebSocketTransport.swift`): a recursive `receiveMessage` from within its completion, feeding a continuation, with close-vs-error tracking. Note this is a **pull *consumer* API over an eagerly-buffered receive** — the transport keeps issuing `receiveMessage` and buffers internally; it is *not* demand-driven at the socket (no backpressure). True demand-driven reads are deferred (§ Additional Considerations / out of scope). The pull surface is a thin reshape of what's there; the outbound dial path is the only genuinely new transport code.
- **Seamless mid-stream format change is kept**, moved wholesale from `SendspinClient+MessageHandling.swift` / `SendspinClient+AudioLoops.swift` into `AudioEngine` as an engine-internal detail (no more `MainActor.run` hop for `pendingFormat`). Isolating it makes a future "is seamless worth it?" call cheap, but the default is keep.
- **State-before-event invariant is preserved** from `SendspinClient+MessageHandling.swift` (metadata/controller-state applied before emitting their events). The one normalization: lifecycle is *uniformly* render-applied (today's format-change path sets `currentStreamFormat` pre-swap; this aligns it with initial-start).
- **`MockTransport`** (`Tests/SendspinKitTests/Helpers/MockTransport.swift`) already isolates client tests from real transports; it gains a `nextFrame()` surface and remains the integration-test seam.
- **Divergence:** the `connectionGeneration` lifetime pattern (`SendspinClient.swift`) is *removed*, replaced by object identity + explicit `shutdown()` + identity guard. Justified because the generation pattern forced N teardown sites each re-validating an integer after every `await`; the replacement centralizes lifetime to one shutdown root + one guard.

## Additional Considerations

**Interop safety net.** The cross-implementation conformance suite (sibling repo, audio-hash equality across PCM/FLAC/Opus/24-bit/metadata/artwork/controller) is the ground-truth interop check. A SendspinKit-only `swift test` run does **not** exercise it, so Phases 3 and 5 (the interop-sensitive ones) must run conformance explicitly as a gate, not rely on the in-repo suite alone.

**Examples are a recompile surface.** The seven `Examples/` packages are standalone SPM packages that depend on SendspinKit locally and exhaustively `switch` over `ClientEvent`; they are not built by the main package's `swift test`/CI, so an `events` reshape breaks them silently until built. Updating + compiling them is an explicit Phase 5 deliverable.

**Network.framework adoption risks (Phase 3).** `NWConnection.cancel()` does not reliably unblock an in-flight `receiveMessage` (it can hang ~60s); mitigated by finishing the internal buffer on the connection-state handler so `nextFrame()` returns `nil` immediately. `wss://` requires explicit TLS `NWParameters`. Keepalive pings are manual, but constant clock-sync traffic keeps the socket non-idle, so no app-level ping timer is planned. The protocol uses no WebSocket-layer compression (audio is codec-compressed), so `NWProtocolWebSocket`'s lack of `permessage-deflate` is a non-issue.

**`stream/end` semantics preserved.** `stream/end` stops output and clears buffers per spec; the ordered channel guarantees it is *processed* after preceding chunks, then truncates scheduled-not-yet-played audio. That truncation is intended; drain-to-final is explicitly not taken.

**Operational-state ownership.** `clientOperationalState` (synchronized / error / externalSource) becomes single-writer: the connection owns it (it sends `client/state`), and the `AudioEngine` reports underrun/error transitions up via its `reports` stream, which the connection drains.

**Future extensibility — Alt C (two public streams).** If a consumer ever needs cross-class (binary↔lifecycle) ordering, the escape hatch is splitting `events` into a data-plane stream and a control stream — the deferred "per-role host APIs." The two-producer model here is the Tier-1 compromise that keeps the single `events` shape while moving the data plane off the MainActor.
