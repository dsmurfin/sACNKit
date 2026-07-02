# sACNKit Modernization - Phase 1: Foundation & Safety Net (Detailed Plan)

## Context

This executes **Phase 1** of `MODERNIZATION.md` (foundation-first): a modern toolchain, CI, and a
regression **test net that captures current behavior** before the SwiftNIO (Phase 3) and actor/async
(Phase 4) rewrites - plus the cheap crash-safety fixes, the one confirmed transmit bug, the hot-path
allocation quick win, and cross-platform prep for the two non-socket Darwin APIs. The intended outcome:
green CI on macOS, meaningful coverage of the layers + merger + transmit state machine, and **no
behavior change except crash-safety and the confirmed TX correctness fix**. Findings below were verified
against the code by exploration agents (exact lines cited).

## Process & branching (do this first)

- Create branch **`modernization-phase1`** from `modernization-plan` (currently `c64696f`).
- **Commit this plan as `docs/modernization/phase-1.md` before any code**, so work is resumable from
  another session. (New `docs/modernization/` folder.)
- All Phase 1 work lands on `modernization-phase1`, one focused commit per step, each gated on green CI.

## Guardrails / non-goals

- **No concurrency redesign** (Phase 2/4). Bumping tools-version to 6.0 makes Swift 6 the *default*
  language mode, which floods the GCD/delegate code with strict-concurrency errors - so pin
  **`swiftLanguageModes: [.v5]`** package-wide to keep current code compiling. This pin is temporary
  (removed in Phase 4).
- **No SwiftNIO** (Phase 3). CocoaAsyncSocket stays; it is unaffected by the higher floors and builds
  fine under a Swift 6.2 toolchain (Obj-C module, not concurrency-checked).
- **Only behavior changes allowed:** the 3 force-unwrap crash-safety fixes, the confirmed
  `sendDataMessages` indexing fix, and the `DMPLayer.parse` wrong-error-type fix. Everything else is
  behavior-preserving.
- **Linux does not compile yet** (CocoaAsyncSocket blocks it until Phase 3). Cross-platform prep here is
  compile-guarded and *validated* on Linux in Phase 3; Phase 1 CI is macOS-only.

## Workstreams

### A. Toolchain & manifest - `Package.swift`
- `swift-tools-version` 5.5 -> 6.0 (requires the Swift 6.2 toolchain to build).
- `platforms: [.iOS(.v17), .macOS(.v14), .tvOS(.v17), .visionOS(.v1)]` (`.visionOS` needs tools >= 5.9;
  fine at 6.0).
- Add package-wide `swiftLanguageModes: [.v5]`; leave per-target `swiftSettings:` hooks empty for later.
- `Package.resolved` (v1 legacy) will auto-rewrite to the newer schema on first resolve - commit it.

### B. Repo hygiene
- `.gitignore`: replace the narrow `.swiftpm/xcode/package.xcworkspace/contents.xcworkspacedata` line
  with `.swiftpm/`. (`.build/` already ignored.)
- `git rm --cached .swiftpm/xcode/package.xcworkspace/xcshareddata/IDEWorkspaceChecks.plist` - this file
  **is currently tracked**, so gitignore alone won't remove it.
- Optional: drop the vestigial `import Network` in `Shared/ComponentSocket.swift` (no `NW*` usage).

### C. Cross-platform prep (non-socket Darwin APIs) - compile-guarded, validated on Linux in Phase 3
- **`Shared/Universe/Source.swift`** `getDeviceName()` (lines ~46-52) + import guard (26-28): change
  `#if os(iOS)` to **`#if canImport(UIKit)`** (covers iOS/tvOS/visionOS/Catalyst - fixes the
  tvOS/visionOS force-unwrap risk the new floors introduce), `#elseif canImport(Darwin)` (macOS) returns
  `Host.current().localizedName ?? ProcessInfo.processInfo.hostName` (removes the force-unwrap), `#else`
  (Linux) returns `ProcessInfo.processInfo.hostName`. Guard the UIKit import with `#if canImport(UIKit)`.
- **`Shared/MonotonicTimer.swift`** `getMilliseconds()` (93-95): `#if canImport(Darwin)` keeps
  `clock_gettime_nsec_np(CLOCK_UPTIME_RAW)`; `#else` uses Glibc `clock_gettime(CLOCK_MONOTONIC, &ts)`
  (add `#if canImport(Glibc) import Glibc #endif`).

### D. Confirmed bug + crash-safety fixes (behavior-changing, behind tests)
- **TX indexing bug** - `Source/sACNSource.swift:869-870`: iterate `for universe in activeUniverses {`
  and drop `universes[index]`. `activeUniverses` holds the same reference-type `SourceUniverse`
  instances, so in-place mutation stays correct. **Applied inside the extracted builder (workstream G).**
- **Force-unwraps:** `Receiver/sACNReceiver.swift:120` -> `guard let receiver = ... else { return nil }`
  (failable init); `Receiver/sACNReceiverGroup.swift:135` -> `guard let ... else { throw
  sACNReceiverValidationError.universeNumberInvalid }`; the `Source.swift:50` host-name unwrap is removed
  via workstream C.
- **Wrong error type** - `Layers/DMPLayer.swift:105` throws `DataFramingLayerValidationError` inside
  `DMPLayer.parse`; correct to `DMPLayerValidationError.invalidFlagsAndLength` (characterize first).

### E. Cheap non-behavioral cleanups
- `Shared/DMX/DMX.swift:33` `public static var addressCount` -> `let` (no writes anywhere; 22 reads).
  Note: technically source-breaking for an external consumer that *mutated* it - acceptable pre-1.0.
- `Shared/Definitions/NetworkDefinitions.swift:81,84,104,107` multicast prefix/hostname statics
  `var` -> `let` (no writes).
- Dead `newSocketIds`: delete `Source/sACNSource.swift:416,420` and
  `Receiver/sACNDiscoveryReceiver.swift:268,272`. **Do NOT touch `Receiver/sACNReceiverRaw.swift`**
  (its `newSocketIds` at ~350/354 is read at 363 - it's live).

### F. Hot-path allocation (SE-0349) - `Shared/Data+Extensions.swift`
- Delete the custom `UnsafeRawPointer.loadUnaligned(atOffset:as:)` extension (234-251, allocates per
  read). Re-point the accessors `toUInt8`/`toUInt16`/`toUInt32` (lines 39/50/61) to the stdlib
  `loadUnaligned(fromByteOffset:as:)`, keeping `$0.baseAddress?` (preserves the optional return) and the
  trailing `.bigEndian`. `toUUID` (71-78) benefits automatically. Guard with the round-trip tests (H1).

### G. Testability seam - extract the transmit builder (approved)
- Split `sACNSource.sendDataMessages()` (`Source/sACNSource.swift:806-959`) into: an **internal pure
  builder** `buildDataMessages() -> (messages: [UniverseData], socketTermination: [UniverseData])` (no
  socket I/O; returns packets to send) + the existing sender loop (`sockets.forEach { ... send }`) that
  calls it. Promote the `private typealias UniverseData` to internal.
- **Two-step, to protect correctness-critical code:** (1) extract with **zero logic change** and prove
  identical output via the characterization tests (H4); (2) *then* apply the indexing fix (D) and assert
  the corrected behavior. Preserve the current mutation order (`incrementSequence` / `decrementDirty` /
  `prioritySent` / `incrementCounter`).

### H. Characterization + new tests (`swift-testing`)
Migrate `DMPLayerTests` to `import Testing` (`#expect`); delete the empty `sACNKitTests.swift`. XCTest and
swift-testing coexist (no manifest change needed - bundled with the 6.2 toolchain), so migrate
incrementally. Suites (all `@testable import sACNKit`; layers/merger/SourceUniverse need no seams):
1. **Layer round-trip + malformed:** `UniverseDiscoveryLayer` and `DMPLayer` (canonical 512) round-trip
   directly; `RootLayer`/`DataFramingLayer`/`UniverseDiscoveryFramingLayer` need a flags-and-length patch
   (`replacing*FlagsAndLength`) before self-parse - mirror `updateUniverseDiscoveryMessages()`
   (`sACNSource.swift:755-785`) for realistic nested fixtures. Malformed cases via `#expect(throws:)`:
   truncated (`lengthOutOfRange`), bad vector, bad priority/universe, wrong preamble/packet-identifier,
   odd universe-list length; plus the corrected `DMPLayer` error type.
2. **Merger characterization** (`sACNMerger`, fully synchronous, public API): add/remove source,
   `updateLevels`/`updatePAP`/`updateUniversePriority`/`removePAP`; assert `levels` + `winners` for
   HTP-within-highest-priority, priority-0 unsourced, universe-priority -> per-slot (0->1), tie-break
   stability, `sourceLimit`, and invalid-level-count throwing. Optionally widen
   `perAddressPriorities`/`perAddressPrioritiesActive`/`universePriority` to `internal private(set)` to
   assert transmit outputs.
3. **SourceUniverse primitives** (zero seam): `incrementSequence` wrap 255->0; `incrementCounter` cycle
   0..43 wrap; `decrementDirty` floor 0; dirty burst = 3 after `update`; `terminate(remove:)` sets
   `shouldTerminate` + `dirtyCounter = 3`; `reset()` state.
4. **TX emission via `buildDataMessages()`** (needs seam G): 3 termination packets after `terminate()`;
   sequence increments per emitted packet; keep-alive at `transmitCounter` 0/11/22/33 across a 44-frame
   cycle; dirty burst of 3 after a level change; and the **indexing-fix regression** (a present-but-
   inactive universe must not cause the wrong universes to be processed or the tail to be dropped).

### I. CI - GitHub Actions (new `.github/workflows/ci.yml`)
- macOS runner (Xcode providing Swift 6.2): `swift build` + `swift test`. **Linux deferred to Phase 3.**
- Format check job: `swift format lint --strict --configuration .swift-format --recursive Sources Tests`.

### J. Docs
- **DocC scaffold:** `Sources/sACNKit/Documentation.docc/sACNKit.md` landing article with a `## Topics`
  grouping (Source / Receiver / Discovery / Merger). No manifest change to build docs.
- **README:** add Requirements (Swift 6.2; iOS 17 / macOS 14 / tvOS 17 / visionOS 1), Installation (SPM
  snippet), a minimal `sACNSource` + `sACNReceiver` usage example, DocC link, and a License section.
- **`CONTRIBUTING.md`:** build/test/format commands, branch/commit conventions, links to
  `MODERNIZATION.md` and this plan.

## Sequencing (one commit each, green CI gate)
1. Plan doc (`docs/modernization/phase-1.md`).
2. Toolchain + hygiene (A, B) - builds under 6.0 / `.v5`.
3. Cross-platform prep (C) - compiles on Apple.
4. Test infra + characterize **current** behavior (H1-H3; migrate `DMPLayerTests`) - baseline captured.
5. Extraction seam (G, no logic change) proven identical via H4.
6. Confirmed + crash-safety fixes (D) with corrected-behavior assertions.
7. Cheap cleanups (E) + hot-path allocation (F).
8. CI (I) + Docs (J).

## Verification
- `swift build` (Swift 6.2 toolchain) succeeds under language mode `.v5`.
- `swift test` - all suites pass.
- `swift format lint --strict --configuration .swift-format --recursive Sources Tests` clean.
- Behavior-preservation: the extraction step (5) produces byte-identical `buildDataMessages()` output vs.
  the pre-refactor capture; the fix step (6) corrects only the present-but-inactive-universe case.
- CI green on macOS. Cross-platform paths compile on Apple; Linux runtime is validated in Phase 3.

## Risks / notes
- **Highest risk: the `sendDataMessages` extraction** - mitigated by characterize-first, extract-with-no-
  logic-change, then fix.
- `Package.resolved` schema bump on resolve is expected/benign.
- `swiftLanguageModes: [.v5]` is a temporary bridge until Phase 4 enables Swift 6 mode.
- Making public `DMX.addressCount` a `let` is technically source-breaking for external mutators (none
  known); acceptable pre-stable.

## Key files
`Package.swift`, `Package.resolved`, `.gitignore`, `.swiftpm/` (untrack), `Shared/Universe/Source.swift`,
`Shared/MonotonicTimer.swift`, `Shared/DMX/DMX.swift`, `Shared/Definitions/NetworkDefinitions.swift`,
`Shared/Data+Extensions.swift`, `Source/sACNSource.swift`, `Source/SourceUniverse.swift`,
`Receiver/sACNReceiver.swift`, `Receiver/sACNReceiverGroup.swift`, `Receiver/sACNDiscoveryReceiver.swift`,
`Layers/DMPLayer.swift`, `Tests/sACNKitTests/*` (swift-testing suites), `.github/workflows/ci.yml`,
`Sources/sACNKit/Documentation.docc/`, `README.md`, `CONTRIBUTING.md`, `docs/modernization/phase-1.md`.
