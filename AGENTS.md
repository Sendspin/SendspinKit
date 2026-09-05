# SendspinKit

Swift client library for the Sendspin Protocol — synchronized multi-room audio on Apple platforms.

## Tech Stack
- Swift 6.2+ (strict concurrency), SwiftPM. iOS 17 / macOS 14 / tvOS 17 / watchOS 10, non-Apple OSes are explicitly out of scope.
- Transport: `Network.framework` (`NWWebSocketTransport`) — no third-party WebSocket dep.
- Codecs: native Opus (AVAudioConverter `kAudioFormatOpus`), flac-binary-xcframework, ogg-binary-xcframework.
- Tests: Swift Testing (`@Test`/`#expect`), not XCTest.

## Pre-commit Gate (MANDATORY, CI-enforced)
Run on changed files before every commit: `swiftformat --lint .` and `swiftlint lint --strict`.
`swiftformat <files>` (no `--lint`) auto-fixes most violations.

After a public API change also run `./scripts/build-examples.sh` (~20s). Each package
under `Examples/` depends on `path: "../.."`, so `swift build`/`swift test` never compile
them and drift ships green; CI enforces this in the `Examples` job. Some examples switch
exhaustively over `ClientEvent` on purpose — add the missing case, not a `default:`.

## Project Structure
- `Sources/SendspinKit/Client/` — MainActor facade, connection actor, handshake, message handling, and state-preference APIs. See its AGENTS.md.
- `Sources/CElligator/` — vendored libsodium field operations and RFC 9380 Elligator2 composition used by CPace. Keep this target verbatim to its recorded upstream provenance; it contains no authored field arithmetic.
- `Sources/SendspinKit/Audio/` — `AudioEngine` actor, data-plane channel, scheduler, decoders, and measured buffer-depth reporting.
- `Sources/SendspinKit/Transport/` — `SendspinTransport` pull interface (`nextFrame`, `sendRawText`, `sendBinary`, `disconnect`) + `NWWebSocketTransport`; Noise framing lives here.
- `Sources/SendspinKit/Synchronization/` — Kalman clock sync (`ClockSyncProtocol`) and scheduled-update time estimates.
- `Sources/SendspinKit/{Models,Discovery}/` — wire types, role state models, pairing descriptors, and mDNS/Bonjour discovery.
- `docs/implementation-plans/`, `docs/test-plans/` — design/AC history and manual gates.

## Conventions
- No magic values in tests — import the source constant (binary type bytes, role strings, reasons,
  `highWatermark`, etc.).
- Tautological tests are the recurring failure mode here: every behavior test must fail when the
  production code it guards is mutated. Reviews mutation-test claims.
- When running tests while developing, *always* set a timeout. The entire suite runs under 30
  seconds cold, and 4 seconds warm. Anything taking longer than that is a immediate red flag.
  Another recurring failure mode is *not* setting timeouts, leaving tests running in the background
  that then hold locks, and then you waste many minutes kicking off tests that will never return.
- **Never cite line numbers** — not spec line numbers (`spec §485`), not source line numbers
  (`AudioPlayer.swift:38`), not in code, comments, docs, or these AGENTS files. They rot the moment
  anything above them shifts, and the spec is moving fast. Reference by stable name instead: the
  symbol, the message type, or the spec's section heading (e.g. "the player role's `client/state`
  player object").
- Comments explain the non-obvious *why*, not the bug's history. A fix's narrative belongs in the
  commit message or CHANGELOG; the comment should be what a maintainer needs to avoid
  reintroducing the problem. Two filters that catch most bad comments:
  - **Past tense is a smell.** "They disagreed 3 vs 2", "this used to spin forever" describe code
    that no longer exists. State the invariant in the present: "both must use the count
    `prepare()` primes".
  - **Would it go on every declaration of this kind?** If the comment explains why something is
    *normal* (a test that needs no hardware, a function that returns what it says), it is noise.
    Comment the exception, not the default.

## Sendspin Spec
- We aim to be a 100%-compliant Sendspin client, which means conforming to the spec at https://www.sendspin-audio.com/spec/
- Interoperability with sendspin servers is tested via the conformance suite: https://github.com/Sendspin/conformance
