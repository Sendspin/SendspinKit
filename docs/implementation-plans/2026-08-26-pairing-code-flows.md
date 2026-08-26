# CPace Pairing-Code Flows — Phased Implementation Plan

Status: draft — implementation plan only; no production code is included in this change
Date: 2026-08-26
Spec source: `../spec` (pairing.md in full; messaging.md and management.md pairing sections) — authoritative and ahead of the published website; verify every wire detail against the local files before implementation
Reference implementation: `../aiosendspin` (`aiosendspin/noise/pairing.py`, `aiosendspin/noise/pin.py`, `aiosendspin/client/connection.py`, and the pairing tests)
Integration gate: `../conformance` when pairing-code scenarios exist; final live gate is Music Assistant's provider PIN flow (`_run_pin_pairing_flow`)

This plan implements both client-side code methods, `dynamic_pairing_code` and
`static_pairing_code`. It does not implement server-side pairing. `source@v1`,
`visualizer@v1`, and unrelated protocol work remain outside this plan.

## Ground rules

- **No compatibility detours.** Implement the current local Sendspin wire shapes. Do not preserve an older PIN protocol, variable-length dynamic PIN behavior, or alternate field names merely because a reference implementation supports them. The local spec's dynamic `digits` value is exactly six digits; static pairing code is exactly eight decimal digits.
- **The library never persists.** The library provides provider protocols and in-memory defaults, but the host app owns durable static-code configuration, the dynamic failure counter, pairing records, identity material, and any user-facing operator state. A durable provider must make each mutation atomic from the library's point of view.
- **Library-not-app boundary.** Pairing-window gestures and code emission are app hooks. The library cannot observe a physical button, speaker, display, QR renderer, or language service. It owns protocol state, timing, validation, and event emission; the host app decides how a gesture is detected and how an emitted code is shown or spoken.
- **Crypto is delegated to an audited dependency.** Do not hand-roll field arithmetic, Elligator2, Montgomery ladders, point validation, or scalar multiplication in Swift. CPace must use `CPACE-X25519-SHA512` as specified by draft-irtf-cfrg-cpace-21. SHA-256/HMAC and the existing cipher-suite AEAD wrapper may remain in the existing CryptoKit-based code where the protocol calls for them, subject to the crypto review.
- **Comment discipline (re-read this every phase).** Comments state present-tense invariants, briefly. One clause of *why*, not a paragraph of justification; no restating the symbol name, no narrating what a review found, no defending a default. The root AGENTS.md filters apply: past tense is a smell, and a comment that would fit every declaration of its kind is noise. When in doubt, delete it.
- **No plan-artifact references in code.** Code comments, symbol names, and doc comments must never cite acceptance-criterion IDs, phase numbers, review findings, or anything else that only exists inside this plan. Reference stable protocol names, message types, and spec headings instead.
- **No app-facing delegate proliferation.** Prefer the existing `ClientEvent` stream and small value types. Add a new delegate protocol only if the event stream cannot safely carry the required app hook.
- **Architecture remains load-bearing.** The dependency remains facade → connection → engine. CPace and pairing state live below the `@MainActor` facade; the connection remains the transport's single writer; no `@MainActor` type is imported by `SendspinConnection` or crypto code.
- **Every phase ends with:** `swiftformat --lint .` + `swiftlint lint --strict` clean, the full Swift Testing suite green under a timeout and under 30 seconds cold, `./scripts/build-examples.sh` green, and the four-model review gate with findings adjudicated rather than rubber-stamped. After public API changes, the examples build is mandatory.

## Current groundwork and required rework

The Noise/spec-alignment work leaves useful but incomplete foundations:

- `PairingMessages.swift` currently models `pair/abort`, Pairing PSK's direct `client/pair-finalize`, `server/pair-finalize`, and `server/unpair`. It does not yet model `client/pair-pending`, `client/pair-init`, `server/pair-init`, `server/pair-auth`, `client/pair-auth`, `server/pair-confirm`, or `client/pair-confirm`, nor the mutually exclusive direct/wrapped finalize fields.
- `PairMethodDescriptor` already has optional `outChannels`, `formats`, and `locations`, so the wire shape is present but its construction and validation must become code-method-aware. `dynamic_pairing_code` requires a non-empty `formats` array and may advertise `display`/`speaker` in `out_channels`; static code and Pairing PSK use `locations` and do not carry `formats`.
- `SendspinConnection+MessageHandling.swift` currently starts only the Pairing PSK flow from `server/activate`, clears the attempt on `pair/abort`, and treats code methods as unsupported. Its lifecycle must become a single serialized state machine for all three methods.
- `PairingManagementConfiguration` has only Pairing PSK, record mode, and unpaired-access state. It needs enabled flags and static-code material, while the failure counter must be persisted separately or as an explicitly durable part of the same provider contract. The static secret must never be returned by `get-pairing-config`.
- The management responder deliberately rejects code-method patches and always returns `invalid` for `open-pairing-window`; both behaviors must be replaced with the spec's patch, validation, persistence, and window semantics.
- `NoiseChannel.handshakeHash` already exposes `h` after transport establishment. `NoiseSessionEstablisher` and `HandshakeDriver.Result` do not currently carry it explicitly, so the implementation must either carry the 32-byte value in the handoff or guarantee that the connection captures it before any rekey. Re-handshake must reset the pairing-activate counter.
- The connection has a `pairingAttemptTimeout` and Pairing PSK's pending PSK state, but no code-method attempt state, pairing-index counter, window state, window expiry task, or serialized pairing-window cancellation path.
- `MockNoiseServer` currently verifies hello shape and can inject activations, but has no CPace implementation or pairing-code driver. It must grow an independent server-side transcript driver for tests without putting CPace production code in the test helper's place of authority.

## Protocol invariants to implement

### CPace inputs and roles

Use `CPACE-X25519-SHA512` from draft-irtf-cfrg-cpace-21. The server is CPace party A (initiator); the client is party B (responder):

- `PRS` is the exact pairing-code byte string. For `digits`, it is the contiguous ASCII decimal digits encoded as UTF-8. Dynamic is six digits; static is eight. For `qr_code`, it is the 24 raw code bytes, not the QR token's ASCII representation.
- `sid` is the raw concatenation `"sendspin-pair-pake-v1" || h || counter(uint32 big-endian)`, where `h` is the 32-byte Noise handshake hash and `counter` is the number of pairing `server/activate` messages received since the last Noise handshake. The counter is session-scoped, starts at zero after each Noise handshake, increments for each pairing activation, and is never inferred from a stale message; therefore the first pairing attempt after a handshake carries `counter = 1` under this definition, cross-checked against an independent transcript fixture rather than assumed.
- `CI` is empty; `ADa` is UTF-8 `"server"`; `ADb` is UTF-8 `"client"`.
- CPace produces 32-byte public shares and a 64-byte `ISK`/MCF output as defined by the draft. The wire fields are base64url without padding: shares are 43 characters and confirmation tags are 86 characters. `wrapped_psk` and `wrapped_nonce_B` each carry 48 bytes (32-byte plaintext plus the AEAD tag), encoded as 64 base64url characters.
- The primitive must implement the draft's X25519 generator derivation: `generator_string` with the CPace domain separation, SHA-512 output, RFC 7748 u-coordinate decoding, and RFC 9380 Elligator2 map-to-curve. `G_X25519.scalar_mult` and `scalar_mult_vfy` are X25519, with invalid/low-order input represented as the neutral/error result. Do not substitute `crypto_core_ed25519_from_uniform` or Ristretto APIs. Add an independent MCF-tag known-answer test for both `Ta` and `Tb`; if draft Appendix B has no explicit tag vectors, generate the known answer from cpace-py.

### Dynamic flow

After a pairing `server/activate` selects `dynamic_pairing_code` and a supported format:

1. If the dynamic method is not escalated, send `client/pair-init` immediately. If it is escalated and no window is open, send `client/pair-pending` and wait; opening the window sends `client/pair-init`. A pre-open window is consumed by the attempt without sending `pair-pending`.
2. Generate a fresh 32-byte `nonce_B`, retain it only for this attempt, and send `commit_B = SHA-256("sendspin-pair-commit-v1" || nonce_B)` in `client/pair-init` with the matching `pairing_index`.
3. Receive and validate `server/pair-init.nonce_A` as exactly 32 decoded bytes. Derive `digest = SHA-256("sendspin-pairing-code-derive-v1" || h || nonce_A || nonce_B)`. For `digits`, interpret the full digest as a big-endian integer modulo `10^6` and zero-pad to six ASCII digits. For `qr_code`, use `digest[0..23]` as the raw 24-byte code and emit the version-1 `SP:1` pairing token containing those bytes.
4. Emit the code through one `ClientEvent` payload carrying the format and code value. The digits value is contiguous six digits; presentation grouping (`3-3`) is app-only. A QR value is the complete token string, not a display-specific image type. Apply the activation's optional language list only in an app-provided spoken-emission hook; language mismatch is informational and cannot abort the protocol.
5. Start CPace as responder with the selected `PRS`, `sid`, and `ADb=client`. Receive `server/pair-auth`, validate/decode `pake_msg_1`, derive with `ADa=server`, and send `client/pair-auth` with `pake_msg_2`.
6. Receive `server/pair-confirm`, verify `server_kc` in constant-time through the CPace implementation. If verification fails, increment the single persisted dynamic failure counter, send `pair/abort pairing_code_mismatch`, discard all attempt state, and clear the emitted-code event. If it succeeds, reset the counter to zero even if the server later cancels instead of finalizing.
7. Send `client/pair-confirm` with `client_kc` and `wrapped_nonce_B`, then immediately send `client/pair-finalize` without waiting for a server response. Derive each wrapping key as `SHA-256(label || sid || ISK)`; use the connection's negotiated AEAD (`ChaChaPoly` or `AES-GCM`), a 12-byte all-zero nonce, and empty associated data. The nonce wrapper uses `sendspin-pair-nonce-wrap-v1`; the PSK wrapper uses `sendspin-pair-psk-wrap-v1`.
8. Persist the new record only after `server/pair-finalize`, as the existing Pairing PSK flow does. A cancelling `server/activate` discards the PSK and all code state and does not affect the failure counter.

### Static flow

After a pairing `server/activate` selects `static_pairing_code`:

1. Every attempt is gesture-gated. If no window is open, send `client/pair-pending`; when the window opens, consume it and send `client/pair-init`. The five-minute window lifetime is a recommended bound; make it injectable for tests.
2. Load the configured eight ASCII decimal digits from the host-owned configuration. Never emit them from the library and never expose them in `get-pairing-config`.
3. Send `client/pair-init` with the current `pairing_index` and no `commit_B`. Start CPace as responder with the eight digit UTF-8 `PRS`, `sid`, and `ADb=client`.
4. Exchange `server/pair-auth`/`client/pair-auth`, verify `server_kc`, and send `client/pair-confirm` with `client_kc` and no `wrapped_nonce_B`. A static attempt with `commit_B` or `wrapped_nonce_B` is a protocol error. Static failures do not increment or reset the dynamic failure counter.
5. Send `client/pair-finalize` immediately after `client/pair-confirm`, with only `wrapped_psk`; use the same label/sid/ISK/AEAD/zero-nonce/empty-AD wrapping rules as dynamic. Wait for `server/pair-finalize` before persisting.

### Window, index, cancellation, and errors

- A window admits exactly one code-based attempt. Its lifetime timer stops when `client/pair-init` is sent; the window closes on completion, inner-authentication failure, `pair/abort`, connection drop, operator cancellation, lifetime expiry, or attempt timeout. `management/open-pairing-window` is a no-op success when already open and is `invalid` only when no code method is enabled.
- `client/pair-pending` does not start an attempt or its two-minute attempt timeout. The timeout starts with `client/pair-init`; the window lifetime starts when the app gesture or paired management request opens the window. On attempt timeout, the client sends `pair/abort` with the exact reason `attempt_timeout`.
- The client sends `pairing_index` in `client/pair-pending` and `client/pair-init`: it sends the current count of pairing `server/activate` messages since the last Noise handshake and discards its own stale attempt state under the spec's silent-discard rule. The spec assigns comparison of a lower or higher value to the server; its rule is: “A value lower than the server's own count is a leftover from a superseded pairing and is discarded silently; a higher value is a protocol error.” This plan does not invent an inbound client index check. Out-of-sequence pairing messages are protocol errors unless the spec's silent-discard rule applies.
- The existing single-attempt-per-connection state machine and multi-server arbitration handle concurrency. A second attempt on the same connection sends `pair/abort concurrent_attempt`; per the spec's reason table, the sender closes the connection after sending.
- A cancelling `server/activate` abandons the attempt, discards every received/generated secret, and does not touch the failure counter. A server-sent `pair/abort user_cancelled` should be surfaced as an ordinary attempt termination; a client cancellation sends the same reason.
- Malformed/missing fields, wrong lengths/encodings, invalid or low-order CPace shares, a failed commitment opening, a binding mismatch, or failed AEAD unwrap are protocol errors: close the WebSocket silently, persist nothing, and emit no application-level protocol error. Receiving `server/pair-init` during a static attempt is also an out-of-sequence protocol error and silently closes the WebSocket. A failed CPace MCF confirmation is different: send `pair/abort pairing_code_mismatch` and keep the connection open.
- After successful code pairing, reuse the existing re-handshake and post-finalize record persistence path. The new long-term PSK is never sent in cleartext in a code flow.

## Dependency decision and open primitive gate

### Evidence gathered

The current `jedisct1/swift-sodium` package is the best packaging baseline:

- The release page currently exposes tag `0.9.1`: <https://github.com/jedisct1/swift-sodium/releases/tag/0.9.1>.
- Its current `Package.swift` uses a prebuilt `Clibsodium.xcframework` for macOS, Mac Catalyst, iOS, watchOS, tvOS, and visionOS, with a system-library path for non-Apple platforms: <https://raw.githubusercontent.com/jedisct1/swift-sodium/master/Package.swift>.
- Its README says the Apple binary is included and identifies the current master binary as built from a libsodium revision; it documents Apple watchOS support and the `Sodium`/`Clibsodium` products: <https://raw.githubusercontent.com/jedisct1/swift-sodium/master/README.md>.
- Current libsodium is at version 1.0.21, but SendspinKit should pin the Swift package tag and record the resolved libsodium revision/checksum rather than float with master: <https://github.com/jedisct1/libsodium/releases>.
- The public `crypto_scalarmult_curve25519` operation (also exposed through the generic `crypto_scalarmult` API) supplies X25519 scalar multiplication and returns failure for invalid/low-order inputs; it is the usable building block for CPace's `scalar_mult`/`scalar_mult_vfy` boundary, but it does not implement CPace's generator derivation by itself: <https://raw.githubusercontent.com/jedisct1/libsodium/master/src/libsodium/include/sodium/crypto_scalarmult_curve25519.h>, <https://raw.githubusercontent.com/jedisct1/libsodium/master/src/libsodium/include/sodium/crypto_scalarmult.h>.
- No public libsodium function implements CPace `G_X25519.calculate_generator` (the RFC 9380 Elligator2 map from the decoded X25519 u-coordinate). `crypto_core_ed25519_from_uniform` is an Ed25519 point/hash-to-group primitive, not that function; current libsodium also exposes Ed25519/Ristretto APIs rather than a public X25519 RFC9380 Elligator2 generator API: <https://doc.libsodium.org/doc/advanced/point-arithmetic>, <https://raw.githubusercontent.com/jedisct1/libsodium/master/src/libsodium/include/sodium/crypto_core_ed25519.h>, <https://raw.githubusercontent.com/jedisct1/libsodium/master/src/libsodium/include/sodium/crypto_core_ristretto255.h>.
- The CPace draft explicitly requires X25519 generator derivation through u-coordinate decoding and RFC9380 Elligator2, and defines both X25519 scalar operations as X25519: <https://www.ietf.org/archive/id/draft-irtf-cfrg-cpace-21.txt>. Its Appendix B contains X25519/SHA-512 vectors, including generator and low-order-point sections; the CFRG repository generates the appendices from Sage sources: <https://github.com/cfrg/draft-irtf-cfrg-cpace>, <https://github.com/cfrg/draft-irtf-cfrg-cpace/tree/master/poc>.

### Provisional decision for implementation

**Experiment outcome (executed): MISMATCH.** Monocypher `crypto_elligator_map`
(commit 1830c06d) does not reproduce the draft's `calculate_generator` vector
(input `03998087…e4aed153` → Monocypher `97ef2dc8…cd72fe23` vs expected
`d04bf6d4…2f05a73f`); bit-mask variants don't close the gap, the algebraic
diagnosis shows the draft's value is RFC 9380 Elligator2 with Z=2 while
Monocypher implements a different documented convention, and the cpace-py
oracle independently confirms the expected value. Phase A therefore takes the
fallback branch below: the vendored-libsodium fe25519 composition shim.

Phase A begins with a **bounded vector experiment**, not an implementation commitment. Run the draft-irtf-cfrg-cpace-21 Appendix B `calculate_generator` vectors against Monocypher's `crypto_elligator_map`, feeding `SHA-512(generator_string)` through RFC 7748 `decodeUCoordinate` exactly as the draft specifies. Run the same vectors against `arturpragacz/cpace-py` as the second test oracle. This pure-Python CPACE-X25519-SHA512 implementation targets draft-21, passes the official vectors, and is the implementation on which aiosendspin depends; use it for independent A-side transcript fixtures as well. It is not a shipped dependency: Python and non-constant-time code are unsuitable for production.

If the bounded experiment matches, the generator map comes from Monocypher's small, audited C implementation under its permissive license, usable on all Apple platforms. Pin `https://github.com/jedisct1/swift-sodium.git` at `0.9.1`, consume the `Clibsodium` binary target rather than the broad Swift convenience API, and record the resolved binary/libsodium revision. Use libsodium only for `crypto_scalarmult_curve25519` behind `scalar_mult`/`scalar_mult_vfy` and any other primitives already used by SendspinKit. If the vectors do **not** match, proceed directly to the fallback: vendor libsodium **source** and add a ≤~30-line C composition shim exposing its internal `fe25519` field operations composed into the RFC 9380 §6.7.1 Elligator2 Montgomery map plus the draft's generator derivation. The fallback is composition only: no newly authored field arithmetic. Both branches end with vector-pinned generator, scalar, ISK, and MCF behavior.

Explicitly rule out `jedisct1/cpace`: it is CPace-Ristretto255 based on the stale draft-haase-cpace-01, so it uses the wrong group and is wire-incompatible. Also rule out any Ed25519/Ristretto `from_uniform`/`from_hash` substitution. There is no “narrow C shim around a verified libsodium-compatible CPace implementation” artifact to select; the only permitted shim is the bounded composition fallback above. If either branch cannot be made vector-conformant, stop and return to the operator rather than hand-roll arithmetic or silently ship an incompatible variant.

The current Swift package conditions do include watchOS, so there is no evidence-based watchOS packaging gap in `swift-sodium` 0.9.1. Still run an actual watchOS 10 build in Phase A because a binary slice can be present in package conditions yet fail deployment/signing/toolchain validation. If the selected replacement packaging genuinely lacks watchOS, leave the operator question unresolved: either drop watchOS from `Package.swift` or compile pairing-code flows out on watchOS while retaining the rest of the library; do not make that decision in implementation.

## Phase A — Dependency boundary and CPace-X25519 primitive

**Goal:** land the dependency/package boundary and an independently testable CPace-X25519-SHA512 implementation with no Sendspin wire or public-client behavior changes.

### Work

- Add and pin the selected libsodium SPM dependency or the minimal vendored `Clibsodium` target. Document the binary revision/checksum, licenses, Apple slices, and the watchOS 10 build result.
- Define a narrow internal CPace value/API boundary that owns role, `PRS`, `sid`, `CI`, associated data, generated share, derived `ISK`, and MCF tags. Keep raw secrets internal and non-`Codable`; only the pairing state machine may request wire encodings.
- Implement the exact X25519/SHA-512 generator path through the dependency boundary. Verify the dependency's map output and scalar validation against the draft rather than relying on a client/server round trip.
- Provide deterministic test injection for scalars/random bytes only in tests; production scalar and nonce generation must use CSPRNG-backed dependency facilities.
- Add draft Appendix B fixtures for `calculate_generator`, scalar multiplication, invalid/low-order points, MCF/ISK, and both CPace roles. If the draft's embedded vectors are encoded in the appendix, decode the generated JSON once into test resources and cite the draft subsection in test names, not comments.
- Add a small wrapper for the existing `NoiseCipherSuite` AEAD that performs pairing wrapping with a 12-byte zero nonce and empty associated data, tested for both suites. Keep the existing Noise transport nonce counter separate from pairing-wrap nonce semantics.

### Review gate A

- Crypto review compares every CPace input, generator step, transcript ordering, role/AD assignment, error result, and confirmation tag against draft-irtf-cfrg-cpace-21.
- A dependency maintainer review confirms no field arithmetic or point validation is implemented in Swift or the shim, and confirms the selected symbols are actually present in the pinned binary for iOS 17, macOS 14, tvOS 17, and watchOS 10.
- Vectors fail if the map is accidentally replaced by Ed25519/Ristretto, if byte order or length-prefixing changes, if the initiator/responder ADs are swapped, or if low-order input is accepted.

## Phase B — Dynamic flow, state machine, wrapping, and app hooks

**Goal:** implement the dynamic method end to end over an established Sendspin connection, including six-digit and QR emissions, commitment/reveal, pairing window behavior for escalated attempts, and finalization.

### Work

- Extend `PairingMessages.swift` with the complete code-flow envelopes and optional fields. Make serialization omit `commit_B`, `wrapped_nonce_B`, and `long_term_psk`/`wrapped_psk` when absent; reject the wrong combination at the state-machine boundary.
- Add a connection-owned `PairingCodeAttempt` state containing method, format, pairing index, Noise hash/sid, nonce/commitment, CPace state, emitted-code identity, timeout task, and whether the window was consumed. Clear it on every terminal path.
- Capture the Noise handshake hash in the handshake-to-connection handoff and maintain the pairing-activate counter. Re-handshake resets the counter and discards stale code state before admitting the next activation.
- Validate activation admissibility dynamically against the live method descriptors/configuration: dynamic requires a supported `format` and `formats` membership; unknown methods or unsupported methods/formats send `pair/abort method_not_supported`, not a decode failure. Route `server/pair-init`, `server/pair-auth`, and `server/pair-confirm` only while the matching dynamic state is active. Enforce exact base64url decoded lengths, one-message-at-a-time sequencing, and the spec's silent-discard rules.
- Generate and emit six-digit or QR token values exactly as specified. Add code-cleared behavior after failure, cancellation, window close, server leave, disconnect, and successful finalization so an app cannot continue displaying a stale dynamic code.
- Add a persistence/provider seam for the single dynamic failure counter. The provider persists only that counter; derive `escalated` for gating and the management field as `counter >= 5`, with no per-connection replica. Increment only on a client-detected failed `server_kc`; reset only on a successful `server_kc`; make the increment-on-failure and escalation read one atomic provider operation. No counter update is allowed for malformed protocol input, server cancellation, static flow, or client/server transport failure.
- Add a KISS facade API for an app gesture: an async `openPairingWindow()` (or equivalent named method) that returns promptly once the window-open intent is recorded/consumed and never awaits attempt completion; a gesture handler must not block for minutes. It opens the connection-owned window and lets a waiting `pair-pending` attempt proceed. Add a cancellation API that sends `pair/abort user_cancelled` when an attempt is in progress and closes local window state otherwise.
- Add a single public `ClientEvent` code event/value carrying `format` and payload. Use contiguous digits in the value; let apps group `3-3`, speak digits, render a QR image, and choose the language. `nil` means cleared and is re-emitted on every terminal path. Do not introduce a display/speaker delegate protocol merely to format output. Surfacing why an attempt ended (mismatch vs cancelled vs timeout) is desirable for app UX; decide a minimal attempt-ended signal (one `ClientEvent` case carrying the abort reason, or equivalent) during Phase B under the existing no-delegate rule, keeping it KISS.
- Grow `MockNoiseServer` with CPace A-side driver support in Phase B, including independently derived A-side transcript fixtures from cpace-py or the CFRG proof of concept; at least one full dynamic transcript must use such a checked-in independent fixture rather than our primitive talking to itself.
- Preserve the current Pairing PSK finalize/re-handshake path and share its “persist only after server acknowledgement” behavior without sharing direct-PSK payloads with code flows.

### Review gate B

- Transcript tests against an independently CPace-capable `MockNoiseServer` pass for dynamic digits and QR, both Noise AEAD suites if the client can negotiate/test both, exact message ordering, emitted-code clearing, and immediate confirm/finalize back-to-back sends. At least one complete dynamic transcript uses a checked-in A-side fixture independently generated by cpace-py or the CFRG proof of concept; draft vectors pin the primitive, while this fixture pins the Sendspin interleaving.
- Security review verifies nonce secrecy until wrapped reveal, commitment binding, code binding to `h`/nonces, no cleartext long-term PSK, and no persistence before `server/pair-finalize`.
- Four-model API/concurrency review confirms the facade remains free of transport/CryptoKit/CPace state and that window, timeout, event, and failure-counter mutations are serialized by the connection/provider contracts.

## Phase C — Static flow and management provisioning/window semantics

**Goal:** implement the fixed eight-digit static method and all client management behavior needed to provision, enable, inspect, and gate it.

### Work

- Extend `PairingManagementConfiguration` with static code material and enabled state, plus dynamic enabled state. Keep secrets out of snapshots returned over management; the provider persists only the dynamic failure counter, from which `escalated` is derived as `counter >= 5`.
- Extend `PairingConfiguration` and `PairingRecordStore` provider seams so an app can supply/load/save a device-specific static code. In-memory defaults may be useful for tests, but production must not use a fixed shared code. Validate exactly eight ASCII decimal digits; enabling without an existing or same-request code is `invalid`.
- Make `management/set-pairing-config` a patch: update only present fields, atomically persist the complete resulting configuration, reject unsupported-method fields, reject malformed static codes, and preserve established records on code rotation. Runtime snapshots must be the single source of truth for future hellos, activation admissibility, pairing, and management.
- Add `static_pairing_code` and `dynamic_pairing_code` method objects to `management/get-pairing-config` when implemented, with `enabled` and dynamic `escalated`; omit a method object only when the implementation is absent. Never return either configured secret.
- Make `management/open-pairing-window` return `invalid` only when no code method is enabled, `ok` when opening a window, and `ok` as a no-op when already open. Only a paired management session may invoke it under the existing management guard.
- Implement static pairing activation handling: every attempt uses the window gate, `client/pair-init` has no commitment, the CPace PRS is the configured eight-digit UTF-8 value, `client/pair-confirm` has no nonce opening, and the PSK is wrapped before finalization. Reject a `format` on static activation and all other dynamic-only fields as protocol errors, and ensure static attempts never alter the dynamic failure counter.
- Ensure a code-method activation quiesces playback according to the server's activation sequence and that a leaving/cancelling activation discards state without treating it as an inner-authentication failure.

### Review gate C

- Management transcript tests cover every patch combination and result (`ok`, `permission_denied`, `invalid`, `storage_exhausted` where the provider supports it), secret omission, static-code rotation, enable-without-code rejection, runtime advertisement, and open-window idempotence.
- Static transcript tests fail if `server/pair-init` is expected, if `commit_B` or `wrapped_nonce_B` is sent, if the code is not eight ASCII digits, if static flow touches dynamic escalation, or if unwrapped PSK is accepted.
- Persistence review verifies static code and dynamic counter durability boundaries, atomic configuration updates, no library-owned filesystem/Keychain storage, and no secret leakage in errors/events/logs.
- Four-model semantics review covers the management tables and activation/window/cancellation matrix.

## Phase D — Integration polish, conformance, and live gate

**Goal:** close model/adapter/documentation gaps and demonstrate interoperability with the reference server implementation and Music Assistant.

### Work

- Wire full live hello descriptors and reconcile live re-handshake advertisements with the same runtime method/configuration snapshot used by the connection: enabled implemented methods, their actual formats, out-channels, and locations must remain consistent after re-handshake; implemented but disabled methods remain represented with `enabled: false` in management and are omitted from hello advertisement.
- Inspect `../conformance/src/conformance` for newly added code-flow scenarios. If scenarios exist, add the SendspinKit adapter's code emitter/window hooks and static configuration path; do not weaken the adapter with unconditional defaults. If no scenarios exist, retain transcript tests as the hard coverage and document that the harness has no code-flow scenario.
- Add the live Music Assistant gate using its provider's `_run_pin_pairing_flow`: exercise at least one dynamic digits flow and one static flow if MA exposes both, including operator/window signaling, CPace confirmation, long-term record reuse, and a failed-code retry. Record whether MA currently calls the methods PIN rather than pairing-code in adapter naming, but test the wire methods from the local spec.
- Update README/DocC/examples for the event and gesture/window APIs, static-code provisioning responsibility, QR token payload, six-digit presentation, and the security distinction between dynamic device-presence binding and static-code MITM exposure. Extend exhaustive `ClientEvent` switches with explicit cases.
- Add a conformance and platform matrix for iOS 17, macOS 14, tvOS 17, and watchOS 10. If pairing code is conditionally unavailable on watchOS due to the selected primitive packaging, document the operator decision and keep the rest of the package build honest.

### Review gate D

- All acceptance tests below are green, conformance scenarios are green when present, examples build, and the live MA provider gate completes.
- Final four-model review audits the full state machine, API ergonomics, provider durability, wire compatibility, and dependency/license/platform evidence.

## API surface

Keep the public surface deliberately small:

1. **Code emission:** add a `ClientEvent` case such as `pairingCodeChanged(PairingCodeEmission?)`. `PairingCodeEmission` is `Sendable`/`Equatable` and contains the selected `format` (`digits` or `qr_code`) and its payload: contiguous six ASCII digits for `digits`, or the complete `SP:1` token string for `qr_code`. `nil` means cleared and is re-emitted on every terminal path. The event is emitted only for dynamic pairing; static code is never emitted.
2. **Window/gesture hook:** add one app-callable async method on `SendspinClient`, `openPairingWindow()`, plus a cancellation method if needed by the existing command style. The call is local intent, not a wire management request, and returns promptly once the window-open intent is recorded/consumed; it never awaits attempt completion, so a gesture handler cannot block for minutes. The connection consumes exactly one open window; the app may invoke it from a physical gesture handler. A paired server's `management/open-pairing-window` uses the same connection-owned window primitive.
3. **Static-code provisioning:** extend the existing `PairingConfiguration`/`PairingRecordStore` configuration seam with an optional static code and method enablement, and let the existing management patch persist rotations. Do not expose a getter that returns the secret through management or an observable facade property. If the final initializer shape would force secret copies on the MainActor, keep the secret in the provider/runtime snapshot consumed by the connection.
4. **No new delegate protocols:** spoken-language choice, grouping, display rendering, QR image generation, speaker playback, and physical gesture detection remain host-app responsibilities. Surfacing why an attempt ended (mismatch vs cancelled vs timeout) is desirable for app UX; decide a minimal attempt-ended signal (one `ClientEvent` case carrying the abort reason, or equivalent) during Phase B under this no-delegate rule, keeping it KISS. The library supplies the raw event payload and protocol/window methods.

## Acceptance criteria and test strategy

Each AC names the test that must fail if the guarded behavior regresses. Swift tests use Swift Testing. A transcript is an exchange with the in-process `MockNoiseServer` after real Noise establishment; a fixture is an independently generated CPace/draft vector, never a client/server self-round trip.

| AC | Behavior | Test (named at implementation, listed layer) |
|---|---|---|
| A.1 | CPace-X25519-SHA512 generator, scalar multiplication, ISK, and MCF match draft vectors | `CPaceX25519VectorTests` using Appendix B fixtures |
| A.2 | CPace initiator/responder roles, `ADa=server`, `ADb=client`, empty CI, transcript order, and `CPace255` DSI agree | `CPaceTranscriptTests` |
| A.3 | Independent MCF known-answer tags `Ta`/`Tb` agree; use cpace-py when Appendix B does not provide explicit tag vectors | `CPaceMCFKnownAnswerTests` |
| A.4 | Invalid, low-order, and non-canonical bit-255 X25519 shares abort; no weak share reaches confirmation | `CPaceInvalidShareTests` |
| A.5 | `sid` uses exact label, raw Noise `h`, and big-endian pairing counter; the first attempt carries the independently fixture-checked current count; re-handshake resets counter | `PairingSessionIdentifierTests` and `RehandshakePairingIndexTests` |
| A.6 | Pairing wrapping uses the selected Noise AEAD, SHA-256 label/sid/ISK, zero nonce, empty AD, and 48-byte ciphertext-plus-tag encoded as 64 base64url characters | `PairingWrapTests` for ChaChaPoly and AES-GCM |
| B.1 | Dynamic digits derives exactly six digits with full-digest big-endian modulo `10^6`, including leading zeroes | `DynamicPairingCodeDerivationTests.digitsUsesSixDigits` |
| B.2 | Dynamic QR derives first 24 digest bytes and emits a valid version-1 token whose payload is those raw bytes | `DynamicPairingCodeDerivationTests.qrEmitsVersionOneToken` |
| B.3 | Dynamic happy path orders init → server nonce → auth → auth → confirm → client confirm + immediate wrapped finalize; persists only after server finalize | `DynamicPairingTranscriptTests.happyPath` |
| B.4 | Dynamic code binds to `h`, both nonces, and commitment; wrong entered/bound code does not finalize | `DynamicPairingTranscriptTests.bindingMismatch` |
| B.5 | Failed `server_kc` sends `pair/abort pairing_code_mismatch`, increments counter, clears code, and leaves the socket usable | `DynamicPairingTranscriptTests.serverConfirmationFailure` |
| B.6 | Counter resets on successful server confirmation and escalates exactly at five persisted failures; escalation does not remove advertisement | `DynamicPairingFailureCounterTests` |
| B.7 | Escalated dynamic attempt sends one `pair-pending` without starting timeout; window opens one attempt; expiry/cancel clears state | `PairingWindowTests.dynamicEscalation` |
| B.8 | Dynamic low-order/malformed share, failed wrap, mismatched commitment, and wrong field shape silently close and persist nothing | `DynamicPairingProtocolErrorTests` |
| B.9 | Unknown methods and unsupported dynamic methods/formats send `pair/abort method_not_supported`; a second attempt on one connection sends `pair/abort concurrent_attempt` and closes after sending | `ActivationAdmissibilityTests` and `PairingConcurrencyTests` |
| B.10 | Attempt timeout sends `pair/abort` with the exact reason `attempt_timeout`, closes the window, clears code state, and leaves no persisted record | `PairingTimeoutTests` |
| C.1 | Static attempt is always window-gated and uses exactly eight configured ASCII digits | `StaticPairingWindowTests` and `StaticPairingTranscriptTests.staticCodeValidation` |
| C.2 | Static flow omits server nonce, commitment, and nonce opening; uses CPace and wrapped finalize correctly | `StaticPairingTranscriptTests.messageShape` |
| C.3 | Static confirmation mismatch aborts without changing dynamic failure counter or persisting a record | `StaticPairingTranscriptTests.mismatchDoesNotTouchDynamicCounter` |
| C.4 | Static dynamic-only fields, a `format`, receiving `server/pair-init` during a static attempt, and unwrapped finalize are protocol errors with silent close and no persistence | `StaticPairingProtocolErrorTests` |
| C.5 | Cancelling activate, abort, timeout, disconnect, and window expiry discard PSK/code state; cancellation does not increment failure counter | `PairingCancellationTests` |
| C.6 | The client sends the current `pairing_index` in `client/pair-pending`/`client/pair-init` and discards its own stale attempt state silently; server-side lower/higher validation is covered only by the server fixture | `PairingIndexSequenceTests` |
| C.7 | `get-pairing-config` reports every implemented method object with `enabled` (and dynamic `escalated`) even when disabled, reports no secrets, and omits only unimplemented method objects | `ManagementPairingCodeTests.getConfigOmitsSecrets` |
| C.8 | Set patch validates eight digits, enable-without-code, unsupported fields, atomic persistence, and rotation semantics | `ManagementPairingCodeTests.setConfigPatchMatrix` |
| C.9 | Open-window returns `ok`, is idempotent while open, and is `invalid` only without an enabled code method | `ManagementPairingCodeTests.openWindowOutcomes` |
| D.1 | Hello descriptors advertise the actual code methods, formats, out-channels, and locations; live re-handshake advertisement matches config | `PairMethodDescriptorTests` and `RehandshakeAdvertisementTests` |
| D.2 | At least one full end-to-end dynamic transcript uses an independently derived A-side fixture from cpace-py or the CFRG proof of concept (not our primitive talking to itself); MockNoiseServer drives both code flows and observes no duplicate public events or stale code emission | `MockNoiseServerPairingDriverTests` |
| D.3 | Conformance adapter code scenarios pass when available; absent scenarios are explicitly documented rather than simulated | `../conformance` pairing scenario job |
| D.4 | Live Music Assistant dynamic/static provider flow pairs, re-handshakes, persists, and reconnects on the long-term PSK | Manual MA gate using `_run_pin_pairing_flow` |
| D.5 | All four Apple deployment targets compile with the selected dependency, including watchOS 10 | platform build matrix |

The mock server surface must grow in Phase B before B.3: it needs CPace A-side primitive access through the same audited dependency boundary or checked-in independent fixtures, activation pairing-method/format selection, operator-code injection, window control, ordered encrypted-message observation, error injection, and finalize/re-handshake driving. At least one full end-to-end dynamic transcript MUST use an independently derived A-side fixture generated by cpace-py or the CFRG proof of concept, not our primitive talking to itself; draft vectors alone pin the primitive, while the independent transcript pins the Sendspin interleaving. A fake that merely echoes client shares is not sufficient evidence.

## Security notes

- Treat the static code as a durable secret. It is device-specific, never a fixed default, never logged, never included in management result data, and never emitted as a `ClientEvent`.
- Dynamic code is bound to the exact Noise handshake hash and pairing activation counter. A relay that creates different Noise handshakes obtains different `sid` values and cannot satisfy the commitment/code binding on both legs.
- Keep `nonce_B`, CPace scalars, shares, `ISK`, wrapping keys, and newly generated long-term PSKs in attempt-scoped memory only. Clear references on all terminal paths where Swift permits it; never persist them as a recovery mechanism.
- Use constant-time MCF/tag, commitment, and code-binding comparisons. Delegate point validation, low-order rejection, scalar clamping/handling, and constant-time ladder behavior to the audited CPace/libsodium dependency. The implementation must still translate dependency failure results into the spec's silent-close behavior.
- Protocol errors close the WebSocket silently and persist nothing. Do not send `pair/abort` for malformed fields, failed commitment opening, binding mismatch, or unwrap failure; reserve `pairing_code_mismatch` for an MCF key-confirmation failure.
- The four-model crypto review must specifically examine: (1) the exact X25519 Elligator2 generator and low-order validation path, including the distinction from Ed25519/Ristretto APIs; (2) CPace transcript/AD/role/length-prefix ordering and MCF tags; (3) `sid`, commit/reveal, dynamic code derivation, QR token encoding, and counter reset semantics; and (4) wrapping key labels, negotiated AEAD selection, zero nonce/empty AD, nonce/key lifetime, and persistence-after-ack ordering.
- Static pairing is cryptographically authenticated but vulnerable if the code is disclosed and does not provide dynamic device-presence binding. Document this to host apps; do not claim static pairing proves the operator is observing the physical device.

## Risks and decisions

- **Dependency API gap:** current swift-sodium/libsodium evidence proves X25519 scalar multiplication and Ed25519/Ristretto mapping APIs, but not a public CPace G_X25519 Elligator2 API. Phase A is a hard gate; no Ed25519 substitution or Swift field arithmetic is acceptable.
- **Draft volatility:** draft-irtf-cfrg-cpace-21 is an Internet-Draft and the local Sendspin spec is authoritative for instantiation. Pin fixtures to the reviewed draft revision and record any later draft change as a deliberate compatibility decision.
- **Reference drift:** aiosendspin's `pin.py` permits 4–12 digits and its tests use configurable dynamic lengths. SendspinKit follows the local spec's six-digit dynamic and eight-digit static requirements; reference sequencing is reusable, reference lengths are not.
- **WatchOS binary validation:** swift-sodium's current package conditions and README claim watchOS support, but the actual selected binary slice and Xcode 26/toolchain must be built. If a replacement lacks watchOS, the operator must choose between dropping watchOS from package platforms and conditional unavailability of pairing-code flows; this plan does not decide.
- **Persistence migration:** extending `PairingRecordStore`/configuration changes public provider requirements. Default protocol extensions may preserve source usability for hosts that do not need code methods, but the final API must not imply that an in-memory static code is safe for deployed devices.
- **No current conformance scenarios:** the current conformance adapter search shows no pairing-code scenario or `_run_pin_pairing_flow` in `../conformance/src/conformance`; transcript tests are the hard gate until scenarios land. The MA provider/live path remains the interoperability gate.
- **Single connection writer:** code emission and window callbacks must never send directly from the facade. All pairing messages and window consumption are serialized through `SendspinConnection`.

## Deferred (explicitly outside this plan)

- `source@v1`: capture pipeline, `client_stream/*`, binary type 12, and source-role conformance.
- `visualizer@v1`: real visualizer support and binary types 16–20.
- Server-side CPace pairing implementation. Tests may use an independent/mock server driver solely to exercise the client wire behavior; no production server is added here.
- App-specific display rendering, QR image generation, speaker/TTS implementation, language lookup implementation, physical gesture detection, UI countdowns, and application storage backends. The library exposes the protocol hooks and event payloads only.
- Pairing token versions beyond the existing version 0 and dynamic QR version 1. The existing version-0 Pairing PSK token remains shared groundwork; this plan does not add a new token family for static codes.
- Automatic static-code rotation, recovery/export UX, cloud backup, and policy decisions about whether a product ships static pairing enabled. The library validates and persists operator-supplied configuration; the host product chooses policy.

## Sequencing and gates summary

| Phase | Deliverable | Gate |
|---|---|---|
| A | Bounded Monocypher/libsodium CPace-X25519-SHA512 primitive experiment and selected vector-pinned dependency boundary, draft vectors, wrapping primitive | vectors + low-order/MCF known-answer tests + dependency/platform/crypto review |
| B | Dynamic six-digit/QR flow, method/format admissibility, commitment/reveal, wrapping, code event, gesture/window and escalation state, independent A-side MockNoiseServer fixtures | dynamic transcripts including an independent A-side fixture, negative matrix, persistence/concurrency review |
| C | Static eight-digit flow, static format rejection, management provisioning/config objects, open-window semantics, and durable counter/code state | static transcripts + management matrix + semantics/security review |
| D | Live re-handshake advertisement reconciliation, conformance adapter, docs/examples, platform matrix, live MA gate | conformance when available + live MA + full lint/tests/examples + final four-model review |
