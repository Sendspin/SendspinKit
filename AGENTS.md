# SendspinKit

Swift client library for the Sendspin Protocol — synchronized multi-room audio on Apple platforms.

## Tech Stack
- Swift 6.2+ (strict concurrency), SwiftPM. iOS 17 / macOS 14 / tvOS 17 / watchOS 10, non-Apple OSes are explicitly out of scope.
- Transport: `Network.framework` (`NWWebSocketTransport`) — no third-party WebSocket dep.
- Codecs: swift-opus, flac-binary-xcframework, ogg-binary-xcframework.
- Tests: Swift Testing (`@Test`/`#expect`), not XCTest.

## Pre-commit Gate (MANDATORY, CI-enforced)
Run on changed files before every commit: `swiftformat --lint .` and `swiftlint lint --strict`.
`swiftformat <files>` (no `--lint`) auto-fixes most violations.

## Project Structure
- `Sources/SendspinKit/Client/` — facade, connection actor, message handling. See its AGENTS.md.
- `Sources/SendspinKit/Audio/` — `AudioEngine` actor, data-plane channel, scheduler, decoders.
- `Sources/SendspinKit/Transport/` — `SendspinTransport` pull interface + `NWWebSocketTransport`.
- `Sources/SendspinKit/Synchronization/` — Kalman clock sync (`ClockSyncProtocol`).
- `Sources/SendspinKit/{Models,Discovery}/` — wire types; mDNS/Bonjour discovery.
- `docs/implementation-plans/`, `docs/test-plans/` — design/AC history and manual gates.

## Conventions
- Files open with two `// ABOUTME:` comment lines.
- No magic values in tests — import the source constant (binary type bytes, role strings, reasons,
  `highWatermark`, etc.).
- Tautological tests are the recurring failure mode here: every behavior test must fail when the
  production code it guards is mutated. Reviews mutation-test claims.
- When running tests while developing, *always* set a timeout. The entire suite runs under 30
  seconds cold, and 4 seconds warm. Anything taking longer than that is a immediate red flag.
  Another recurring failure mode is *not* setting timeouts, leaving tests running in the background
  that then hold locks, and then you waste many minutes kicking off tests that will never return.

## Sendspin Spec
- We aim to be a 100%-compliant Sendspin client, which means conforming to the spec at https://www.sendspin-audio.com/spec/
- Interoperability with sendspin servers is tested via the conformance suite: https://github.com/Sendspin/conformance
