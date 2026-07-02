# sACNKit Modernization - Phase 2: Concurrency Hardening & Sendability

## Context

This executes **Phase 2** of `MODERNIZATION.md`: make the value model `Sendable`-clean, stage
strict-concurrency checking, and close the known queue-safety gaps in the receiver stack - *before*
the Phase 4 actor migration, so that migration becomes incremental rather than big-bang. The library
stays **delegate/GCD-based externally**; no actors, no async API, no SwiftNIO. Phase 1 (toolchain
6.2, `.v5` language-mode pin, macOS CI, swift-testing suites for layers/merger/source-transmit) is
complete and merged (`febf59c`). All findings below were verified against the code (lines cited).

Maintainer decisions (confirmed): the RX data callback **flips sync -> async**, and serial-queue
safety is enforced via an **internal stateQueue** (not documentation-only).

## Verified findings driving this phase

- **Last remaining `.sync` delegate delivery:** `sACNReceiverRaw.swift:657` delivers
  `receiverReceivedUniverseData` via `delegateQueue.sync` while holding `socketDelegateQueue` - the
  documented AB/BA deadlock window. Every other delivery in RX, discovery, and TX is `.async`.
- **Newly found defect - wrong-queue PAP-lost callback:** `sACNReceiverRaw.swift:701` ->
  `ReceiverRawSource.notifyPerAddressLost` (`ReceiverRawSource.swift:171-175`) invokes
  `delegate?.receiver(_, lostPerAddressPriorityFor:)` **directly on the socket queue** - no
  `delegateQueue` hop - racing all serialized callbacks (and `sACNReceiver.perAddressPriorityLost`
  mutates merger state assuming `delegateQueue`).
- **Unsynchronized group state:** `sACNReceiverGroup.remove(universe:)` (`:158-160`) and
  `information(for:on:)` (`:191-194`) access `receivers` with no lock, while `add`/`updateInterfaces`
  use `delegateQueue.sync`. Also: calling `add` from inside a delegate callback self-deadlocks today
  (`delegateQueue.sync` from `delegateQueue`).
- **Unlocked `sACNReceiver` state:** `sources`, `numberOfPendingSources`, `isSampling`, and the two
  `sACNMerger`s are mutated in raw-delegate callbacks (`sACNReceiver.swift:337-366` ext) relying on
  the client queue being serial; `information(for:)` (`:181`) only has a `dispatchPrecondition`.
- **Sendable inventory:** pure-value public types ready for explicit `Sendable`:
  `sACNSourceUniverse`, `sACNReceiverMergedData`, `sACNReceiverSource`, `sACNReceiverRawSourceData`,
  `sACNDiscoveryReceiverSource`, `sACNMergerConfig`, `sACNMergerError`, `sACNIPMode`,
  `DMX`/`DMX.STARTCode`, all 5 layer structs + nested `Vector`/`Offset`/`Options` +
  `*ValidationError` enums, internal `Source` struct. No mutable statics/global state remain
  (Phase 1). `MonotonicTimer` is a small mutable class - cheap struct conversion.
- **`Error?` delegate params are NOT a blocker:** SE-0302 makes `Error` refine `Sendable`; no
  protocol signature changes needed (corrects an earlier assumption in MODERNIZATION.md notes).

## Process & branching

- Branch **`modernization-phase2`** (from `modernization-plan` / merged main state, per user).
- **Commit this plan as `docs/modernization/phase-2.md` before any code** (Phase 1 precedent), so
  work is resumable across sessions.
- One focused commit per step, each gated on green CI.

## Guardrails / non-goals

- No actor/async redesign (Phase 4), no transport change (Phase 3). `swiftLanguageModes: [.v5]` stays.
- No public API signature changes; delegate protocols untouched.
- **No `@unchecked Sendable` on engine classes** - irreducible targeted-mode warnings are
  inventoried (they are the Phase 4 worklist), never silenced with false conformances.
- Allowed behavior changes only: (1) RX data delivery sync -> async; (2) PAP-lost delivered on
  `delegateQueue`; (3) `sACNReceiver`/`sACNReceiverGroup` internal serialization (safety-only);
  (4) delegate refs captured at dispatch time. No wire-format or merge-behavior change.

## Workstreams

### A. Manifest - `Package.swift`
- Add `swiftSettings: [.enableExperimentalFeature("StrictConcurrency=targeted")]` to **both**
  targets (library + tests), with a comment noting removal in Phase 4 (Swift 6 mode = complete).
- Why this spelling: `.enableUpcomingFeature("StrictConcurrency")` is complete-mode (Phase 4);
  `unsafeFlags` breaks consumption as a package dependency. `.v5` already equals `minimal`, so the
  only flip is to `targeted` (warnings, not errors, under `.v5`).
- Run a local uncommitted recon build at `StrictConcurrency=complete`; record the warning inventory
  in the phase doc's completion notes (Phase 4 worklist).
- Lands **after** workstream B so the flip is warning-clean (or with an honest inventory).

### B. Sendable adoption (declaration-only)
Explicit `: Sendable` (public types get no cross-module inference) on the inventory above:
`Source/sACNUniverse.swift`, `Receiver/Delegate/*.swift` DTOs, `Merger/sACNMerger.swift`
(config + error), `Shared/Definitions/NetworkDefinitions.swift` (`sACNIPMode`),
`Shared/DMX/DMX.swift`, `Layers/*.swift` (structs, nested types, validation errors), other public
error enums (`sACNReceiverValidationError`, `sACNComponentSocketError`, `sACNSourceValidationError`),
internal `Shared/Universe/Source.swift`.
Plus: **`MonotonicTimer` class -> struct** (`Shared/MonotonicTimer.swift`) - all six usage sites
store it as `var` in classes, so `mutating` compiles without call-site changes; removes per-source
heap allocations; then `Sendable`. Add the monotonic-clock test Phase 1 never actually added.

### C. Queue-safety fixes (each behind tests, verified-to-fail first where feasible)
- **C1 - PAP-lost wrong-queue fix (`:701`):** refactor `notifyPerAddressLost` into a pure state
  check on `ReceiverRawSource` (e.g. `markPerAddressPriorityLost() -> Bool`, guarding the
  once-only flag on the socket queue); `sACNReceiverRaw` then delivers via `delegateQueue.async`
  with the delegate captured before the hop.
- **C2 - data delivery sync -> async flip (`:657`):** one-line flip + update the "data is provided
  synchronously" comment and any doc comments promising synchronous delivery. Ordering is preserved
  (same serial FIFO queue); what changes is synchronous read-back - documented in README/changelog.
- **C3 - capture-before-hop + delegate-setter hygiene:** in `sACNReceiverRaw` (and mechanically in
  `sACNDiscoveryReceiver`/`sACNSource`), read `delegate`/`debugDelegate` on the owning queue and
  capture into the async block; move `setDelegate`/`setDebugDelegate` onto the socket queue using
  the existing `DispatchSpecificKey` sentinel pattern (kills the set-from-callback deadlock and
  cross-queue delegate reads). No observable change; TSan-guarded.
- **C4 - `sACNReceiver` internal stateQueue:** add
  `private let stateQueue = DispatchQueue(label: ..., target: delegateQueue)` + a
  `DispatchSpecificKey` sentinel (mirror `sACNReceiverRaw`'s). Pass `stateQueue` as the inner
  `sACNReceiverRaw`'s delegateQueue (init `:126`). All raw-delegate callbacks then serialize on
  `stateQueue` even for concurrent client queues, while still executing in the client queue's
  context (client-side `dispatchPrecondition(.onQueue(clientQueue))` still passes).
  `information(for:)`: replace bare precondition + unguarded read with sentinel + `stateQueue.sync`
  (callable from any context).
- **C5 - `sACNReceiverGroup` stateQueue + race fixes:** same pattern; group's `stateQueue` targets
  the client queue and is handed to child `sACNReceiver`s as their delegateQueue (children's
  stateQueues target the group's - one serialized hierarchy). `remove`/`information(for:on:)` gain
  sentinel + `stateQueue.sync`; `add`/`updateInterfaces` swap `delegateQueue.sync` for the same
  helper (also fixes the add-from-callback self-deadlock).

### D. Test seams + receiver test suites (new; RX coverage is currently zero)
Seams promoted to `internal` (Phase 1 precedent: `buildDataMessages`, `universes`):
- `sACNReceiverRaw.process(data:ipFamily:socketId:hostname:)` (`:545`) - packet-in -> delegate-out
  without sockets; `socketDelegateQueue` (`:43`) `private let` -> `let` so tests dispatch correctly;
  `beginSamplingPeriod`/`endedSamplingPeriod` (`:435`/`:455`) and `checkForSourceLoss` (`:484`);
  `sourceLossTimeout` (`:125`) static -> instance `let` with internal init parameter (default
  2500 ms) so PAP-expiry tests run fast.
- Packet fixtures reuse Phase 1 layer builders / `buildDataMessages()`.

New suites (`swift-testing`): `ReceiverRawTests.swift`, `ReceiverTests.swift`,
`ReceiverGroupTests.swift`, `MonotonicTimerTests.swift`:
1. Delivery characterization (pre-flip, survives it): `sACNReceiverRawSourceData` payload fidelity,
   sequence filtering, preview filtering, per-packet `isSampling` capture.
2. Ordering regression: N crafted packets -> N in-order data callbacks on the delegate queue.
3. Deadlock regressions: re-enter `isListening`/`stop()` from within the data callback (semaphore +
   timeout, fails instead of hanging; verify it hangs pre-fix once); `information(for:)` from
   (a) inside a callback, (b) the client's serial queue, (c) an unrelated queue; group
   add/remove/information from callbacks.
4. PAP-lost: levels + PAP -> expire wait -> assert callback fires exactly once **on the delegate
   queue** (assert via test-owned `DispatchSpecificKey` + `#expect`, not `dispatchPrecondition` -
   a failed precondition crashes the test process).
5. Group race stress: `concurrentPerform` over add/remove/information - real assertion mechanism is
   the TSan job (E).
6. Loopback integration smoke test (`sACNSource` -> `sACNReceiver` over lo0 multicast) gated behind
   an env flag via `.enabled(if:)` - multicast on shared CI runners is flaky; opt-in locally,
   not CI-required.

### E. CI - `.github/workflows/ci.yml`
- Add a Thread Sanitizer job: `swift test --sanitize=thread` (macos-26). This is the real assertion
  for every race fix in this phase.
- Optional, once warning-free: a `swift build -Xswiftc -warnings-as-errors` step to lock in zero
  targeted-mode warnings (CI-only; never in the manifest).

### F. Docs
- README + DocC + `.claude/rules/threading.md`: universe data is now delivered asynchronously like
  every other callback; delegate queues may be concurrent without corrupting state (serial still
  recommended); `information(for:)` callable from any context; PAP-lost queue fix noted.
- MODERNIZATION.md: tick Phase 2, record the `Error`-is-Sendable correction and the newly found
  `:701` defect, append the strict-concurrency warning inventory (Phase 4 worklist).

## Sequencing (one commit each, green CI gate)

1. Plan doc (`docs/modernization/phase-2.md`).
2. Test seams + receiver characterization tests capturing current behavior (D1/D2 + MonotonicTimer
   tests on the current class).
3. C1 (PAP-lost queue fix) + exactly-once/queue tests (verified-to-fail first).
4. C2 (sync -> async flip) + deadlock + ordering regressions (deadlock test verified-to-hang pre-fix).
5. C3 (capture-before-hop, setter hygiene) - mechanical, TSan-guarded.
6. C4 + C5 (stateQueues) + deadlock/stress tests.
7. B (Sendable adoption + MonotonicTimer struct).
8. A (targeted strict concurrency) + warning triage (`@preconcurrency import CocoaAsyncSocket` in
   `ComponentSocket.swift` if needed; `@preconcurrency` imports as last resort; never
   `@unchecked Sendable`); inventory any irreducible warnings in the phase doc.
9. E (TSan CI job, optional warnings-as-errors) + F (docs).

## Verification

- `swift build` / `swift test` green under `.v5` + `StrictConcurrency=targeted`; warnings zero or
  explicitly inventoried.
- New receiver suites pass deterministically without sockets; loopback test passes locally behind
  the env flag.
- Deadlock regressions all complete within timeout; `swift test --sanitize=thread` clean including
  the group stress test.
- Public API surface unchanged (diff review of `public` declarations); behavior deltas limited to
  the four documented ones.
- `swift format lint --strict --configuration .swift-format --recursive Sources Tests` clean; CI green.

## Risks / notes

- **Highest risk: the sync -> async flip is client-observable** (loses synchronous read-back;
  ordering preserved). Mitigate with doc/changelog notes; it is the RX<->TX alignment
  MODERNIZATION.md calls for, and the maintainer has approved it.
- **`stateQueue.sync` from the client's serial (target) queue** relies on GCD executing sync blocks
  inline on an idle child of the current queue (thread-based ownership). Standard pattern
  (state queue targeting `.main`), but it is exactly what the dedicated deadlock tests prove on CI.
  If any context deadlocks in practice, fall back to a non-targeting internal queue + async hop for
  delegate delivery for that type (documented deviation).
- **Targeted-mode warning volume unknown** until the recon build; fallback is `@preconcurrency`
  imports + honest inventory, never `@unchecked Sendable`.
- Timing-based PAP tests can flake on loaded runners - keep margins generous via the short-timeout
  seam (e.g. 50 ms timeout, 500 ms wait bound).
- `sACNReceiverGroup.remove` gains synchronization only; stop-on-remove semantics (receiver stops
  via deinit on last release) unchanged.

## Completion notes (July 2026)

All workstreams landed. Deviations from this plan and results, in execution order:

- **The stateQueue-targeting-the-client-queue design was rejected empirically.** The plan's Q2
  approach (internal serial queue with `target: delegateQueue`, sync-down from the client queue
  assumed inline-safe) is not viable: GCD's deadlock detection **traps with SIGTRAP in
  `_dispatch_sync_f_slow`** when `sync`ing onto a child queue from its target's context (verified
  with a minimal standalone reproduction, and caught by the planned `information(for:)`
  three-context deadlock tests before commit). The risk section's documented fallback was
  implemented instead: `sACNReceiver` and `sACNReceiverGroup` each own an **independent serial
  `stateQueue`** (sentinel + `performOnStateQueue`), and delegate notifications **hop asynchronously
  to the client's delegateQueue** (capture-before-hop). Consequences: callbacks still execute on the
  client's queue; each type's key is private (no shared hierarchy key); one extra async hop per
  notification; no `sync` ever crosses component queues.
- **Additional test seams beyond the plan:** `perAddressPriorityWait` joined `sourceLossTimeout` as
  an instance timing override (both via the internal `sACNReceiverRaw` initializer);
  `sACNReceiver.receiver` (the internal raw receiver) was promoted to internal so the merge pipeline
  is drivable without sockets; `socketsSampling` gained internal read access for sampling-path tests.
- **Strict-concurrency results:** `targeted` builds **warning-clean** on both targets - no
  `@preconcurrency` imports were needed (the plan's fallback was unused). CI locks this in with
  `swift build -Xswiftc -warnings-as-errors`.
- **Complete-mode recon inventory (the Phase 4 worklist):** 240 diagnostics, all of the expected
  shape - non-Sendable `self`/`delegate`/`ComponentSocket` captures in `@Sendable` dispatch closures,
  plus captured-`var` mutations in `checkForSourceLoss`. Per file: `sACNReceiverRaw` 66,
  `sACNReceiverGroup` 51, `sACNSource` 45, `sACNDiscoveryReceiver` 42, `sACNReceiver` 36. No
  `@unchecked Sendable` anywhere.
- **Verification:** 73 tests pass (deterministic, socket-free); the full suite is clean under
  `swift test --sanitize=thread` locally and in a new CI job; the deadlock regressions were each
  verified to hang/fail against the pre-fix code before the fix landed; the opt-in loopback test
  (`SACNKIT_NETWORK_TESTS=1`) passes locally in ~1.5 s (one sampling period).
- **Doc corrections recorded in MODERNIZATION.md:** the receiver delegate deadlock window and the
  serial-queue requirement are closed; the newly found wrong-queue PAP-lost delivery
  (`ReceiverRawSource.notifyPerAddressLost`) is fixed; `Error` already refines `Sendable` (SE-0302),
  so delegate `Error?` parameters were never a blocker.

## Key files

`Package.swift`, `Sources/sACNKit/Receiver/sACNReceiverRaw.swift`,
`Sources/sACNKit/Receiver/ReceiverRawSource.swift`, `Sources/sACNKit/Receiver/sACNReceiver.swift`,
`Sources/sACNKit/Receiver/sACNReceiverGroup.swift`,
`Sources/sACNKit/Receiver/sACNDiscoveryReceiver.swift`, `Sources/sACNKit/Source/sACNSource.swift`,
`Sources/sACNKit/Source/sACNUniverse.swift`, `Sources/sACNKit/Receiver/Delegate/*.swift`,
`Sources/sACNKit/Merger/sACNMerger.swift`,
`Sources/sACNKit/Shared/{MonotonicTimer,DMX/DMX,Definitions/NetworkDefinitions,Universe/Source,ComponentSocket}.swift`,
`Sources/sACNKit/Layers/*.swift`,
`Tests/sACNKitTests/{ReceiverRawTests,ReceiverTests,ReceiverGroupTests,MonotonicTimerTests}.swift`
(new), `.github/workflows/ci.yml`, `docs/modernization/phase-2.md`, `README.md`,
`.claude/rules/threading.md`, `MODERNIZATION.md`.
