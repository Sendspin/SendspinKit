# Noise/PSK Spec Alignment — Phased Implementation Plan

Status: v2 — revised after 4-model plan review (Opus 4.8, GLM 5.2, GPT-5.6-terra,
DeepSeek-V4-Flash), findings adjudicated 2026-08-23
Spec source: `../spec` (connection.md, messaging.md, management.md, pairing.md, roles/)
— authoritative and AHEAD of the published website; always verify against the local
files, not sendspin-audio.com
Reference implementation: `../sendspin-rs` (branch `fix/sendspin-spec`, verified live
against a Music Assistant server on both cipher suites)
Integration gate: `../conformance` (the harness server speaks the new protocol; the
SendspinKit adapter at `../conformance/adapters/SendspinKit/client` is updated as part
of this effort)

## Ground rules

- **No backward compatibility.** No API compatibility for library consumers, no wire
  compatibility with pre-Noise servers. Old message shapes are deleted, not deprecated.
- **The library never persists.** Everything the spec says a client "persists" —
  identity keypair, pairing records, last-playback server, `output_delay_ms`, volume —
  is surfaced through provider protocols the host app implements
  (extend the existing `SendspinPersistenceProvider` pattern). In-memory defaults
  make tests and examples work without an app.
- **Crypto is hand-rolled on CryptoKit.** Verified 2026-08-23: the Swift Noise
  ecosystem is a proof-of-concept package (`swift-libp2p/swift-noise`) and an
  unmaintained noise-c wrapper (`OuterCorner/Noise`). CryptoKit provides everything
  KKpsk2 needs (Curve25519, ChaChaPoly, AES-GCM, SHA-256, HKDF).
- **Cipher suites:** both AEADs are implemented (each is a thin CryptoKit call behind
  one switch; the Noise core is shared, and sendspin-rs verified live on both), but
  ChaChaPoly is hardwired as the suite sent in `client/init`. No public
  suite-selection API — the suite knob is internal, existing for tests. (Reviewer
  YAGNI finding accepted for the public surface, rebutted for the second AEAD case.)
- **Replacement, not insertion.** The pre-Noise handshake/session layer is deleted,
  not adapted. Legacy symbols scheduled for deletion: `ConnectionReason`,
  `ClientOperationalState` (wire enum — see Phase 2 for the internal-signal split),
  `HandshakePhase`/`awaitingServerHello` sequencing, the facade `performHandshake`
  plaintext probe, old `ClientHelloPayload`/`ServerHelloPayload` shapes,
  `SendspinTransport.send(Codable)` as a protocol-facing contract, and the four-reason
  `GoodbyeReason`. No conditional legacy paths may survive.
- **Out of scope:** `source@v1` (separate future effort), the CPace-based pairing
  flows (`dynamic_pairing_code`, `static_pairing_code` — deferred; they are the only
  work needing crypto beyond CryptoKit, namely Elligator2 map-to-curve), and any
  server-side implementation.
- Architecture invariants from `Sources/SendspinKit/Client/AGENTS.md` hold throughout:
  facade → connection → engine one-way dependency; connection is the transport's
  single writer; no MainActor types below the facade. Where this plan changes a
  documented contract (the facade `performHandshake` exception), the AGENTS.md update
  is part of the phase that changes it, not deferred to Phase 5.
- **Comment discipline (re-read this every phase).** Comments state present-tense
  invariants, briefly. One clause of *why*, not a paragraph of justification; no
  restating the symbol name, no narrating what a review found, no defending a
  default. The root AGENTS.md filters apply: past tense is a smell, and a comment
  that would fit every declaration of its kind is noise. When in doubt, delete it.
- **No plan-artifact references in code.** Code comments, symbol names, and doc
  comments must never cite acceptance-criterion IDs ("AC 0.1"), phase numbers,
  review findings, or anything else that only exists inside this plan or a session.
  Those references are meaningless to a reader who doesn't have the plan open, rot
  the moment the plan is edited, and are painful to strip out later. Same spirit as
  the existing no-line-number rule: reference stable things — the spec section
  heading, the symbol, the message type. The plan maps ACs to tests in *this
  document*; the code and tests themselves speak only in spec/domain terms.
- Every phase ends with: `swiftformat --lint .` + `swiftlint lint --strict` clean,
  full test suite green (< 30 s, always run with a timeout),
  `./scripts/build-examples.sh` green, and the 4-model review gate (same panel as the
  plan review), findings adjudicated — accepted or rebutted, never rubber-stamped.

## Ownership & layering (load-bearing design decision)

Added in v2; three of four reviewers independently flagged this as the plan's biggest
gap. The new handshake is stateful and crypto-bearing, and multi-server arbitration
cannot rank a candidate until its first `server/activate` — the LAST message of the
encrypted establishment flow. So:

- **`HandshakeDriver` (actor, off-MainActor)** owns one candidate establishment
  end-to-end: raw WebSocket transport → `client/init`/`server/init` (retaining the
  exact raw bytes for the prologue) → Noise messages 1/2 (PSK candidate selection via
  the app-provided stores, which may do I/O) → transport mode → `server/hello` →
  `client/hello` → first `server/activate`. Its result is a value:
  `(NoiseChannel, handshake hash h, matched PSK category, trust level,
  activate payload)` — or a classified failure.
- **The facade never touches CryptoKit, the NoiseChannel, or a transport.** For both
  the primary dial and arbitration candidates, the facade starts a `HandshakeDriver`
  and consumes its completed result on the MainActor. Arbitration compares activity
  ranks from completed results; promotion transfers `NoiseChannel` ownership into the
  new `SendspinConnection`. This *removes* the Client/AGENTS.md `performHandshake`
  facade-write exception entirely (the facade's only remaining transport-adjacent act
  is owning driver handles); AGENTS.md is rewritten accordingly in Phase 2.
- **Provisional candidates** (server-initiated inbound connections) are each a live
  `HandshakeDriver`. A candidate that hasn't produced its first `server/activate`
  within 30 s is dropped (spec rule). Rejection replies (`client/goodbye
  concurrent_attempt`, later `pair/abort concurrent_attempt`) are sent by the driver
  on instruction, so the single-writer property holds per channel at every moment:
  driver pre-promotion, connection post-promotion, with an explicit handoff and no
  overlapping `nextFrame()` consumers.
- **`SendspinTransport` shrinks to a raw frame pipe** (send text/binary, pull
  text/binary, close). All protocol knowledge moves up into the driver/channel.

## Phase 0 — Crypto core (no wire changes)

New leaf module, `Sources/SendspinKit/Crypto/`, no dependencies on existing code.
The rest of the library does not change in this phase, so it lands green.

- `SendspinIdentity`: Curve25519 static keypair; `client_id` = base64url(no pad)
  pubkey, 43 chars. Creation from raw secret bytes + generation. An
  identity-persistence hook (protocol) so apps store the private key
  (Keychain is the app's choice, not ours).
- `Psk` + `PskCategory` (long-term / pairing / sentinel), `psk_id` derivation
  (`SHA-256("sendspin-psk-id-v1" || PSK)`), Sentinel PSK + psk_id as tested
  published constants (spec vectors).
- `CipherSuite`: both wire names; ChaChaPoly is the suite the client announces
  (see Ground rules).
- Noise KKpsk2 state machine: HandshakeState/SymmetricState/CipherState,
  client-as-responder only, prologue input, psk2 mixing, **deferred PSK selection**
  (process message 1 payload without PSK, then mix selected PSK before message 2),
  transport-mode counters, handshake hash `h` exposure (re-handshake prologue).
- PSK candidate selection: sentinel + pairing + record PSKs, stored-pubkey
  (verify `server_id` matches record) vs shared-PSK post-match checks.
- **Independent known-answer fixtures** (reviewer finding accepted): check in
  handshake transcripts generated by `sendspin-rs` (snow) — message bytes, `h`,
  transport ciphertexts for both suites — and test our responder against them.
  A Swift-side initiator test double exists only for negative/state-machine tests;
  it is never the sole proof of correctness (a shared bug would round-trip).

**Review gate 0:** crypto review against the spec's Encryption section line by line.

## Phase 1 — Encrypted transport framing

Replace the text-frame JSON transport with the Noise channel. This is the flag-day
phase: nothing interoperates until Phase 2 completes; Phases 1+2 land as one reviewed
unit (review gate 2 covers both — the split is for review size only).

- `NoiseChannel`: encrypts outbound / decrypts inbound; after transport mode *all*
  traffic is binary frames; type byte 0 = JSON, 4 = audio, 8–11 = artwork, 16–23
  = visualizer. Owned per Ownership & layering above.
- Fragmentation (types 2/3): max post-type-byte plaintext per frame is 65518;
  each message type's fixed sub-header (e.g. the 8-byte timestamp) and the first
  fragment's `orig_type` byte come out of that budget — boundary tests at the exact
  thresholds. Inbound reassembly cap of 16 MiB — an implementation-defined DoS guard
  (NOT spec; sized well above the largest legitimate artwork frame), exceeding it
  closes the connection. The three malformed-sequence protocol errors close the
  connection.
- Handshake driver (see Ownership & layering): `client/init` (`client_id`,
  `version: 1`, `suite`) → `server/init` → `noise/handshake` ×2 as text frames;
  prologue = exact raw bytes of the two init messages as sent/received (keep the raw
  Data, never re-encode); version must equal 1 exactly; silent WebSocket close on any
  handshake failure; 30 s per-message phase timeout.
- Re-handshake channel primitive: `noise/handshake` as encrypted JSON in transport
  mode, prologue = prior `h`, key swap boundary (message 2 under old keys, next frame
  under new keys). Driven end-to-end in Phase 3; the primitive + its deterministic
  boundary test land here.
- Mock Noise server harness (in-process, speaks real Noise as initiator): the
  transcript-test backbone for Phases 1–4.

## Phase 2 — New session flow (hello/activate) + state/goodbye reshape

Wire-visible message overhaul. At the end of this phase SendspinKit connects to a
real Music Assistant server (sentinel PSK, unpaired access) and plays audio.

- Message models:
  - `client/init` / `server/init` / `noise/handshake` (used by Phase 1).
  - `server/hello` → `{name}` only. `client/hello` reshaped: drop `client_id`/
    `version` (they live in `client/init`); add `trust_level`,
    `supported_pair_methods` (descriptor array — initially just `pairing_psk` with
    `locations`), `unpaired_access.enabled`. Ordering flips: server speaks first.
  - New `server/activate`: `activities`, `active_roles` (persist-across-activations
    semantics), `pairing` object.
  - **`client/state` wire change is serialization-only** (reviewer finding
    accepted): top-level `available: Bool` replaces the `state` enum on the wire.
    `available = clock-synced && !external-source-occupied`. The *internal*
    engine→connection→facade operational-state signal (`EngineReport
    .operationalState`, `ConnectionEvent`, the epoch-rollback machinery) is retained
    under a non-wire name (e.g. `EngineSyncState`) — engine errors no longer have a
    wire representation and surface via `ClientEvent`/facade state only. Test: an
    engine error does not flip `available`; external-source does.
  - Player rename: `static_delay_ms` → `output_delay_ms`, `set_static_delay` →
    `set_output_delay` end to end. (Verified against `../spec/roles/player/v1.md`;
    the published website lags — one reviewer flagged this from the stale source.)
    Persistence remains a provider hook + docs.
  - `client/goodbye`: add `unauthorized`, `pairing_required`, `concurrent_attempt`,
    `unpaired`.
  - `pair/abort` model + the `method_not_supported` reply are implemented NOW (not
    stubbed — the model is trivial and the admissibility rules need the reply; a
    close-instead-of-abort interim is explicitly rejected).
- Connection sequencing: nothing (not even `client/time`) before the initial
  `server/activate`; clock sync + initial `client/state` start after it. The
  activate that follows a future re-handshake re-arms this gate (see Phase 3).
- `server/activate` admissibility: PSK-category × activity-set table,
  playback-capable rule, response selection (`pairing_required` vs `unauthorized`
  vs `pair/abort method_not_supported`). The `source@v1`-at-`none` rule is a code
  comment only — we never advertise source, so that activation is already an
  unlisted-role violation (reviewer YAGNI finding accepted).
- Multi-server arbitration rewrite per Ownership & layering: rank by highest
  declared activity (management > playback > pairing > empty), provisional
  candidates with 30 s activate timeout, pairing-attempt-not-displaced exception,
  last-playback-server tiebreak for empty-vs-empty, `client/goodbye
  concurrent_attempt` / `another_server` replies. Delete `ConnectionReason`.
  "Last-playback server" = most recent admitted connection holding `'playback'` in
  activities — persistence-provider semantics updated.
- Role activation via `active_roles` (persists across activates that omit it);
  honor server-side quiesce on role removal.
- Visualizer honesty fix: stop advertising `visualizer@v1` (we currently send an
  empty, non-conformant support object). Keep decode tolerance.
- `server/unpair`: model + decode; with no record store yet, the trust-`none`
  ignore rule applies. Full behavior in Phase 3.
- Conformance adapter update (`../conformance/adapters/SendspinKit/client`):
  new connect API (identity + PSK provider), new handshake. Existing
  PCM/FLAC/Opus/metadata/artwork/controller scenarios must pass.
- Client/AGENTS.md rewritten: `performHandshake` exception removed, HandshakeDriver
  contract documented.

**Review gate 2 (covers Phases 1+2):** protocol-flow review + conformance matrix +
live run against Music Assistant (unpaired access).

## Phase 3 — Pairing (Pairing PSK flow) + re-handshake + records

- `PairingRecordStore` protocol (app-persisted; in-memory default): records =
  PSK + optional `server_id` + `used` flag; psk_id uniqueness across categories
  enforced at insert; stored-pubkey and shared-PSK kinds. **`used` write path**
  (reviewer finding accepted): when a handshake authenticates with a record's PSK,
  the connection marks the record used through an async store update; tested via
  a list-records round trip in Phase 4.
- Pairing PSK method: client keeps Pairing PSK among handshake candidates whenever
  enabled; verify matched PSK is the Pairing PSK before `client/pair-finalize`
  (else `pair/abort method_not_supported`); generate + send `long_term_psk`;
  persist record only after `server/pair-finalize`; attempt timeout (2 min) →
  `pair/abort attempt_timeout`; cancelling `server/activate` discards the attempt.
- Version-0 pairing token (`SP:0…`): base32 encode/decode with the 2↔9
  transliteration, lenient decoding, spec reference vectors as tests. Exposed as
  API for the host app (Music Assistant ingests it via its login flow — no operator
  paste; the library just produces/consumes the token string).
- Silent-discard rules for stale pairing messages; protocol-error close semantics.
- Live arbitration sets `MultiServerAdmission.Candidate.isPairingAttempt` for the incumbent once pairing attempts exist; Phase 2 has no pairing attempts.
- Re-handshake end-to-end: server-initiated key swap (sentinel→pairing PSK before
  a pairing activate; pairing→long-term after finalize), fresh
  `server/hello` → `client/hello` (re-assert `trust_level`) → `server/activate`
  after the swap; write-gating during the exchange. **Post-re-handshake semantics
  pinned to sendspin-rs `session.rs`** (reviewer finding accepted): the
  post-swap activate is treated as a fresh initial activate for sequencing (full
  `client/state` resend for re-added roles per messaging.md; `client/time` cadence
  resumes after it).
- `server/unpair` full behavior: remove matched stored-pubkey record (not shared),
  `client/goodbye unpaired`, close; ignore at trust `none`.
- Trust level becomes real: `user` iff a record backs the session.
- All flows covered by mock-server transcript tests (see Test strategy) —
  the live MA gate is a smoke test, not the coverage.

**Review gate 3:** live Music Assistant pair → disconnect → reconnect-on-long-term-PSK
round trip; crypto-adjacent review of re-handshake key-swap boundaries.

**Gate 3 outcome (PASSED):** verified live against head-of-dev Music Assistant —
SP:0 token through MA's setup-flow API, pairing re-handshake, trust `none → user`,
long-term record persisted and reused across reconnects and MA restarts, and
audible FLAC playback. The run surfaced and fixed a real engine bug (format change
during startup priming wedged on the disposed queue). Note: the wire currently
speaks `static_delay_ms`/`set_static_delay` to match deployed servers; flip the
coding keys back once the spec's output-delay rename is mainlined server-side.

## Phase 4 — Management

- All six requests + single `management/result` reply (one-in-flight, ordered):
  `list-records`, `add-record`, `remove-record`, `get-pairing-config`,
  `set-pairing-config`, `open-pairing-window` (rejected `invalid` while no
  pairing-code method exists).
- Gating: `'management'` activity requires a Sendspin-PSK (paired) session, else
  close `unauthorized`; `management/*` outside a management activity →
  `permission_denied`.
- Pairing config surface: `pairing_psk.enabled/psk` (rotation), `record_mode`
  (shared-PSK reference; referential integrity: can't remove a referenced record,
  can't point at a stored-pubkey/missing record — both `invalid`),
  `unpaired_access.enabled`. Pre-provisioned device-unique shared record generated
  on first run through the store provider, never a fixed default. Fields targeting
  unimplemented code methods → `invalid`.
- Removing the requester's own record → result, then `client/goodbye unauthorized`.
- Cross-category psk_id collision checks (`already_exists`).
- Storage accounting passthrough with the spec's exact shape (reviewer finding
  accepted): omitted entirely by the unbounded in-memory default; when the provider
  bounds storage, `storage` appears on every result *except* `permission_denied`,
  always carrying `free`, with `capacity` + costs only on `list-records` and
  `get-pairing-config`.
- Full outcome matrix covered by mock-server tests (see Test strategy); the
  "semantics review" gate is additional, not the coverage.

**Review gate 4:** management semantics review against management.md tables, on top
of the green outcome-matrix tests.

**Gate 4 outcome (PASSED):** four-model panel adjudicated. Accepted and fixed:
store lifecycle wiring (pre-provisioned shared record + persisted config load),
unpaired-access single source of truth via the runtime snapshot, idempotent
pairing-PSK rotation, dead one-in-flight gate removed, unknown management
subtypes answered, and the record-mode storage-exhaustion fallback at
pair-finalize (the fallback PSK is chosen before the wire commit). Rebutted:
open-pairing-window's always-`invalid` is the spec's rule while no pairing-code
method exists.

## Phase 5 — Polish, audit, docs

- Conformance adapter: opt into `supports_request_format` and drive the two
  `stream/request-format` renegotiation scenarios (SendspinKit supports the flow;
  only the adapter capability metadata and trigger wiring are missing).

- Forward-compat audit: unknown payload fields ignored everywhere; we send no
  undefined fields.
- Binary rejection rules re-checked under the new framing; artwork latest-wins +
  empty-payload clear; audio-before-activate gate.
- `client/hello` `supported_pair_methods` reflects live config.
- Public API sweep: new connect surface (identity provider, PSK/record store,
  pairing events in `ClientEvent`), README + example apps updated (exhaustive
  `ClientEvent` switches extended, not defaulted), host-responsibility docs for
  the provider protocols (identity key storage, record atomicity, unpaired-access
  MITM implications, token handling).
- Root + Client AGENTS.md final pass; CHANGELOG; verify every symbol on the
  Ground-rules deletion list is gone.

## Acceptance criteria & test strategy

Each AC names the test(s) that must fail if the guarded behavior regresses.
Unit/transcript tests are Swift Testing; "transcript" = against the Phase 1
in-process mock Noise server; "fixture" = checked-in sendspin-rs-generated bytes.
Live MA runs and conformance scenarios are integration gates recorded per phase,
not substitutes for these.

| AC | Behavior | Test (named at implementation, listed layer) |
|---|---|---|
| 0.1 | KKpsk2 round trip, both suites, vs independent fixtures | fixture tests, Crypto unit |
| 0.2 | Sentinel PSK + psk_id + token vectors match published constants | Crypto unit |
| 0.3 | PSK mismatch fails at message 2; prologue tamper fails; transport tamper/replay/reorder fails | Crypto unit |
| 0.4 | Message 1 processed with NO PSK mixed; PSK mixed exactly before message 2 | Crypto unit |
| 0.5 | Exposed `h` matches fixture; wrong prior-`h` re-handshake prologue fails | Crypto unit |
| 1.1 | Fragmentation split/reassembly at exact 65518-budget boundaries; 16 MiB cap closes | transcript |
| 1.2 | Three malformed fragment sequences each close the connection | transcript |
| 1.3 | Handshake failure closes silently (no app-level message); 30 s phase timeout | transcript |
| 1.4 | Re-handshake key-swap boundary: message 2 under old keys, next frame under new | transcript |
| 2.1 | No outbound frame (incl. `client/time`) before initial `server/activate` | transcript |
| 2.2 | Admissibility matrix: each PSK-category × activity row → correct accept/`pairing_required`/`unauthorized`/`pair/abort` | unit (pure) + transcript |
| 2.3 | `active_roles` persists across activates that omit it; playback-capable re-evaluation | unit |
| 2.4 | Arbitration: activity ranking, provisional 30 s drop, pairing-not-displaced, last-playback tiebreak, goodbye reason selection | unit (pure decision table) |
| 2.5 | `available` true only when clock-synced and not external-source; engine error does NOT flip it | unit |
| 2.6 | Facade holds no NoiseChannel/CryptoKit/transport reference (structural: driver result types) | compile-time shape + review |
| 2.7 | Conformance matrix green (PCM/FLAC/Opus/metadata/artwork/controller) | ../conformance |
| 3.1 | Pairing PSK happy path: finalize order, record persisted only after `server/pair-finalize` | transcript |
| 3.2 | Wrong matched PSK before pair-finalize → `pair/abort method_not_supported` | transcript |
| 3.3 | Attempt timeout → `pair/abort attempt_timeout`; cancelling activate discards PSK, persists nothing | transcript |
| 3.4 | Token v0 encode/decode vs spec reference vector; lenient decode rules | unit |
| 3.5 | Full re-handshake: sentinel→pairing→long-term swaps; write-gating; post-swap activate re-arms sequencing + full state resend | transcript |
| 3.6 | `server/unpair`: stored-pubkey removed / shared kept / ignored at trust none; goodbye `unpaired` | transcript |
| 3.7 | Record store: psk_id cross-category uniqueness; `used` flag set on authenticated session | unit |
| 4.1 | Every management request × outcome row from management.md (incl. referential-integrity `invalid`s, `already_exists`, own-record-removal → goodbye `unauthorized`) | transcript |
| 4.2 | Gating: `permission_denied` outside management activity; close `unauthorized` on management activity without Sendspin PSK | transcript |
| 4.3 | Storage accounting shape (omit on `permission_denied`; capacity/costs only on the two read results) | unit |

## Risks & decisions

- **Flag day (Phases 1+2):** the library is non-functional between them; they land
  as one reviewed unit. Accepted deliberately (single consumer, no compat burden).
- **Hand-rolled Noise:** mitigated by independent sendspin-rs fixtures (AC 0.1),
  spec vectors, and the dedicated crypto review gate — never self-round-trip alone.
- **Live MA availability:** gates 2/3 need a reachable Music Assistant instance.
  Fallback: conformance harness + transcript tests are the hard gate; MA is smoke.
- **Conformance harness scope:** no pairing/management scenarios exist today; those
  phases are covered by transcript tests. If the harness grows scenarios later, we
  adopt them; we do not block on it.
- **Decision:** ChaChaPoly hardwired on the wire; no public suite API (YAGNI). Both
  AEAD cases exist internally.
- **Decision:** `pair/abort` ships in Phase 2, not stubbed.
- **Decision:** engine errors lose their wire representation (spec has none);
  local-only observability via `ClientEvent`. Revisit only if the spec grows an
  error channel.

## Deferred (explicitly out of this plan)

- `source@v1` (role constant, `client_stream/*`, binary type 12, capture pipeline).
- `dynamic_pairing_code` / `static_pairing_code`: CPace-X25519-SHA512 + MCF,
  Elligator2 (needs a crypto decision: custom field arithmetic vs libsodium dep),
  commit/reveal, wrapping, pairing window, failure counter, QR/token v1 emission.
  The `pair/abort` model, pairing-index handling, and token codec from Phases 2–3
  are shared groundwork.
- `visualizer@v1` real implementation (support object, binary types 16–20).

## Sequencing and gates summary

| Phase | Deliverable | Gate |
|---|---|---|
| 0 | Crypto core (identity, PSK, KKpsk2) | AC 0.x + crypto review |
| 1 | Noise channel + fragmentation + handshake driver | AC 1.x (gate shared with Phase 2) |
| 2 | New session flow, arbitration, renames | AC 2.x + conformance + live MA (unpaired) |
| 3 | Pairing PSK + records + re-handshake | AC 3.x + live MA pairing round trip |
| 4 | Management | AC 4.x + semantics review |
| 5 | Audit, docs, API polish | Full suite + examples + review |

Every gate includes the 4-model review panel (Opus 4.8 / GLM 5.2 / GPT-5.6-terra /
DeepSeek-V4-Flash) with findings adjudicated by the primary agent — accepted or
rebutted with evidence, never taken at face value. KISS/YAGNI/SOLID apply to review
findings too: gold-plating suggestions get rebutted, not implemented.
