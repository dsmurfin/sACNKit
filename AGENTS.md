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
  - `Receiver/` (+ `Receiver/Delegate/`) - receive stack: `sACNReceiverRaw` (engine), `sACNReceiver`,
    `sACNReceiverGroup`, `sACNDiscoveryReceiver`, and their delegate/data types.
  - `Merger/` - standalone HTP/priority merge engine: `sACNMerger`, `MergerSource`.
  - `Layers/` - E1.31 wire-format layers (Root / DataFraming / DMP / UniverseDiscovery) as value
    types with `createAsData`/`parse` + typed validation errors; byte offsets centralized per layer.
  - `Shared/` - sockets (`ComponentSocket` protocol + `NIOComponentSocket` SwiftNIO impl,
    `NetworkInterfaceResolver`), timing (`MonotonicTimer`), `Definitions/`, `DMX/`, `Universe/`,
    `Data+Extensions.swift`.
  - `Vendor/CwlDispatch.swift` - vendored GCD timer helpers. **Do not edit by hand** (removed in
    Phase 4 with the async redesign; still used by the **receiver** timers today - the `sACNSource`
    actor's timers already run on NIO scheduled tasks via `sACNRuntime`).
- `Tests/sACNKitTests/` - test target. Coverage is currently thin (`DMPLayerTests` only) and is being
  expanded; see MODERNIZATION.md Phase 1.

## Platforms & toolchain

- Swift tools version: **6.2** (declared in `Package.swift`); language mode is still `.v5` until the
  Phase 4 Swift 6 cutover (MODERNIZATION.md Phase 4).
- Supported platforms (current, in `Package.swift`): **iOS 18 / macOS 15 / tvOS 18 / visionOS 2 + Linux**
  (raised from iOS 17 / macOS 14 / tvOS 17 / visionOS 1 in Phase 4 for `SerialExecutor.checkIsolated`;
  Android/Windows are best-effort stretch targets).
- Concurrency: **mixed, mid-migration.** `sACNSource` is now a Swift `actor` with an `async` API and
  `AsyncStream` events (Phase 4 PR2). The **receivers** are still GCD serial queues (one per component,
  doubling as the state mutex) + weak-delegate callbacks. The actor conversion continues per component
  (MODERNIZATION.md / docs/modernization/phase-4.md); do not assume the receivers are async yet, and do
  not add GCD-queue/sentinel patterns to the `sACNSource` actor.
- Networking: **SwiftNIO** (`Shared/NIOComponentSocket.swift`) behind the internal `ComponentSocket`
  protocol; interface strings are resolved to NIO devices/addresses by `NetworkInterfaceResolver`.
  The transport migration (Phase 3) is done; the `sACNSource` actor's timers already run on NIO scheduled
  tasks, while the GCD/`CwlDispatch` **receiver** timers run until their Phase 4 actor conversion.
  Linux is now a supported build/test target (MODERNIZATION.md).

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
- ALWAYS, **for the GCD receiver components**, mutate a component's state only on its serial
  `socketDelegateQueue` (the queue is the state mutex), and reuse the `DispatchSpecificKey` reentrancy
  sentinel for any method callable both externally and from within the queue - see
  `.claude/rules/threading.md`. (The `sACNSource` actor does not use this: its state is actor-isolated and
  it reserves the `Lifecycle` enum synchronously before each `await`; do not add queue/sentinel patterns
  to it.)
- NEVER add new synchronous cross-queue delegate delivery (AB/BA deadlock hazard - see
  `.claude/rules/threading.md`).
- NEVER edit `Sources/sACNKit/Vendor/CwlDispatch.swift` by hand.
- NEVER change the on-wire packet layout or break public API without review; breaking changes are
  gated to the planned major version (MODERNIZATION.md).

## Detailed rules

Deeper, path-specific detail - read the file when the task touches these areas:
- `.claude/rules/protocol.md` - E1.31 wire format, addressing, packet structure, in-place `Data` replacers.
- `.claude/rules/timing.md` - frame rate, keep-alive/suppression, source-loss, sampling, PAP timing constants.
- `.claude/rules/threading.md` - GCD queue model, reentrancy/deadlock hazards, the serial `delegateQueue` contract.
