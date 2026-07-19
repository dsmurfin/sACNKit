# sACNKit

sACN is a Swift Package Manager implementation of ANSI E1.31-2018 Entertainment Technology Lightweight streaming protocol for transport of DMX512 using ACN (sACN).

It provides a source, receiver, discovery receiver, and advanced features such as raw receiver and merger. It is intended for use in applications that need to send or receive DMX512 data over a network using the sACN protocol.

See README.md for the type overview (usage examples are a modernization Phase 1 deliverable).

The library is mid-modernization - see MODERNIZATION.md for the phased roadmap (SwiftNIO, actor/async
API, Swift 6, cross-platform incl. Linux) and the current-state baseline.

## Build & Test

- Build: `swift build`
- Test: `swift test`
- Lint / format: `swift-format`

## Layout

- `Package.swift` - SwiftPM manifest; single product `sACNKit`, one dependency (SwiftNIO).
- `Sources/sACNKit/` - library source, organized by role:
  - `Source/` - sACN transmit: `sACNSource` (an `actor` with an `async` API + `events`/`debugLog`
    `AsyncStream`s; migrated in Phase 4 PR2), `SourceUniverse`.
  - `Receiver/` (+ `Receiver/Delegate/`) - receive stack, all now `actor`s with `data`/`events`/`debugLog`
    `AsyncStream`s (no delegates): `sACNReceiverRaw` (engine), `sACNReceiver` (merged), `sACNReceiverGroup`
    (facade; migrated in Phase 4 PR4), and `sACNDiscoveryReceiver` (Phase 4 PR3). `Receiver/Delegate/` now
    holds only the `Sendable` payload types (`sACNReceiverRawSourceData`, `sACNReceiverMergedData`,
    `sACNReceiverSource`, `sACNDiscoveryReceiverSource`); the delegate protocols are gone.
  - `Merger/` - standalone HTP/priority merge engine: `sACNMerger`, `MergerSource`.
  - `Layers/` - E1.31 wire-format layers (Root / DataFraming / DMP / UniverseDiscovery) as value
    types with `createAsData`/`parse` + typed validation errors; byte offsets centralized per layer.
  - `Shared/` - sockets (`ComponentSocket` protocol + `NIOComponentSocket` SwiftNIO impl,
    `NetworkInterfaceResolver`), timing (`MonotonicTimer`), `Definitions/`, `DMX/`, `Universe/`,
    `Data+Extensions.swift`.
- `Tests/sACNKitTests/` - test target. Broad coverage: receiver/source/discovery characterization via the
  packet-injection seams, merger, wire-format layers, runtime primitives, monotonic timer, and interface
  resolution, plus socket-binding + source->receiver loopback suites gated behind `SACNKIT_NETWORK_TESTS=1`.

## Platforms & toolchain

- Swift tools version: **6.2** (declared in `Package.swift`); **Swift 6 language mode** (`swiftLanguageModes:
  [.v6]`, Phase 4 PR5), with default actor isolation left `nonisolated` (no package-wide MainActor default)
  and the `NonisolatedNonsendingByDefault` + `InferIsolatedConformances` upcoming features enabled.
- Supported platforms (current, in `Package.swift`): **iOS 18 / macOS 15 / tvOS 18 / visionOS 2 + Linux**
  (raised from iOS 17 / macOS 14 / tvOS 17 / visionOS 1 in Phase 4 for `SerialExecutor.checkIsolated`;
  Android/Windows are best-effort stretch targets).
- Concurrency: **every component is a Swift `actor`** with an `async` API and `AsyncStream` output
  (`sACNSource` PR2, `sACNDiscoveryReceiver` PR3, the receiver vertical - `sACNReceiverRaw`/`sACNReceiver`/
  `sACNReceiverGroup` - PR4). Each actor is pinned to an `sACNRuntime` (NIO) event loop via a custom
  `SerialExecutor`, so the transport delivers inbound packets into the actor's isolation with no `Task` hop.
  No GCD queues, delegates, `DispatchSpecificKey` sentinels, or vendored GCD timers remain; do not
  reintroduce them. Phase 4 is complete (Swift 6 mode is on).
- Networking: **SwiftNIO** (`Shared/NIOComponentSocket.swift`) behind the internal `ComponentSocket`
  protocol; interface strings are resolved to NIO devices/addresses by `NetworkInterfaceResolver`.
  The transport migration (Phase 3) is done; every actor's timers run on NIO scheduled tasks
  (`sACNRuntime.scheduleRepeated`/`scheduleOnce`). Linux is now a supported build/test target (MODERNIZATION.md).

## Conventions

- Public API: every public symbol needs a `///` doc comment (the layers and merger already follow
  this); prefer `final class` for new public types where possible, and subclassing is undesired.
- Error handling: wire-format parsing throws typed `...ValidationError` enums; avoid force-unwraps
  (existing ones are a known cleanup target - see MODERNIZATION.md).
- Wire format: on-the-wire is big-endian; per-layer byte offsets are centralized. Preserve the in-place
  `Data` replacers (sequence / options / priority / levels) - they avoid rebuilding packets at frame rate.
- Dependencies: one - SwiftNIO (products `NIOCore`, `NIOPosix`, `NIOFoundationCompat`,
  `NIOConcurrencyHelpers`); do not add dependencies without discussion.
- Style: `swift-format` is the formatter of record.
- Comments: Comments are encouraged, but avoid cluttering the code with obvious or verbose comments. Use comments sparingly when they add value. Comments should explain why something is done, not what is done. Comments should not document prompt design decisions. Doc comments (`///`) are preferred for public API; inline comments (`//`) are preferred for private implementation details. Avoid block comments (`/* ... */`).
- Prefer switch-as-expression added in SE-0380 over if/else chains for clarity and exhaustiveness.
- Use implicit returns for single-expression functions added in SE-0255 where possible.
- Avoid using emdash character (`—` U+2014) in code comments, documentation and markdown; use hyphen (`-` U+002D) instead.
- First and last properties (or functions) in a type should include a line break before and after them for readability.
- Always aim to use modern Swift features and idioms where possible, but avoid using them in a way that would make the code less readable or maintainable.

## Always / Never

- ALWAYS run `swift test` after changes that touch `Sources/sACNKit`.
- ALWAYS run `swift-format` after changes that touch a `*.swift` file.
- ALWAYS make minimal, focused changes; don't refactor unrelated code.
- ALWAYS keep platform-specific code behind `#if` guards with portable fallbacks (Linux is a target -
  see MODERNIZATION.md).
- ALWAYS keep each component's mutable state actor-isolated: mutate it only within the actor, and reserve
  the shared `LifecycleGate` synchronously (before the first `await`) for start/stop/reconfigure. Do not
  reintroduce GCD queues, `DispatchSpecificKey` sentinels, or delegate callbacks - see
  `.claude/rules/threading.md`.
- ALWAYS keep the raw+merged receiver invariant: `sACNReceiver` owns its `sACNReceiverRaw` on the **same**
  `sACNRuntime`/event loop, so the raw delivers into the merge synchronously on-loop via `RawReceiverSink`
  (`assumeIsolated`). A different runtime for the raw would trap - see `.claude/rules/threading.md`.
- NEVER change the on-wire packet layout or break public API without review; breaking changes are
  gated to the planned major version (MODERNIZATION.md).

## Detailed rules

Deeper, path-specific detail - read the file when the task touches these areas:
- `.claude/rules/protocol.md` - E1.31 wire format, addressing, packet structure, in-place `Data` replacers.
- `.claude/rules/timing.md` - frame rate, keep-alive/suppression, source-loss, sampling, PAP timing constants.
- `.claude/rules/threading.md` - actor/event-loop isolation model, the `LifecycleGate` reserve-before-await
  contract, the raw->merged on-loop sink, and the group's per-child `Task` fan-in.
