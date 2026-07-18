# sACNKit Modernization - Phase 4: Swift Concurrency API Redesign (actors + async)

## Context

This executes **Phase 4** of `MODERNIZATION.md`: the major-version, breaking redesign that replaces the
GCD queue-as-mutex + weak-delegate model with Swift **actors**, removes the mandatory `delegateQueue` init
parameter and all 7 public delegate protocols in favour of `async`/`AsyncStream`, replaces the vendored
GCD timers with NIO scheduled tasks, deletes `Vendor/CwlDispatch.swift`, and turns on **Swift 6 language
mode**. It also dissolves the two Phase-4-gated Linux blockers recorded in the Phase 3 completion note (the
240 concurrency-capture diagnostics and `CwlDispatch`'s Darwin-only `NSEC_*` symbols), which unblocks the
Linux runtime baseline in `docs/modernization/pre-phase-4-baseline.md`.

## Locked decisions (maintainer)

1. **Isolation:** Swift **actors pinned to a custom `EventLoopSerialExecutor` over the shared NIO event
   loop**. Actor reentrancy remains and is handled in code at a few lifecycle sites (it is not removed by
   the executor choice). **Platform floors are raised to macOS 15 / iOS 18 / tvOS 18 / visionOS 2** (from
   14/17/17/1) because the synchronous in-isolation delivery mechanism (`assumeIsolated` from the channel
   handler / timer tick) depends on `SerialExecutor.checkIsolated()`, which is `@available(macOS 15, iOS
   18)` - on older runtimes it is never consulted and `assumeIsolated` from a loop thread would trap.
   (Supersedes the original 14/17 floor; MODERNIZATION.md + AGENTS.md platform sections need the same
   update.) **Delta (PR2, empirical reversal):** PR1 dropped a custom executor in favour of
   `eventLoop.executor`, on the review argument that `SelectableEventLoop` conforms to
   `NIOSerialEventLoopExecutor` and so already supplies `checkIsolated()`. The loopback end-to-end test
   proved this wrong: NIO's `checkIsolated()` is `@available(macOS 15+)` **inside SwiftNIO's precompiled
   module**, and reached through the `any SerialExecutor` existential it resolves to the stdlib **default**
   `checkIsolated()` (`_Concurrency/Executor.swift`), which traps unconditionally ("Unexpected isolation
   context"). The custom `EventLoopSerialExecutor` (compiled at this package's macOS 15 floor, with an
   explicit `checkIsolated()` calling `preconditionInEventLoop`) is required and was restored.
2. **Event API:** **split streams** - a typed high-rate `data` stream (buffering-newest) plus a low-rate
   `events` enum stream, per component.
3. **Staging:** **component-by-component**, each PR building green under Swift 5 language mode; a final PR
   flips to Swift 6 mode and removes the delegate files + `CwlDispatch`.
4. **Test seam:** keep an **internal** packet-injection seam (today's `process(data:)`) as the receiver
   characterization net through the rewrite; do not remove it mid-flight as originally sketched.
5. **Layering:** NIO is kept behind an **internal** `sACNRuntime` seam (executor + timer scheduler + socket
   factory as one matched serial context); component actors, the wire-format codec, and the stream layer
   never name NIO types. Not public API yet - a future alternative transport is then a contained internal
   change. (Continues the Phase 3 discipline of keeping NIO out of the upper layers.)

## Verified findings driving this phase

- Each socket-owning component funnels all state mutation through one serial queue that doubles as the
  socket delegate queue (`sACNReceiverRaw.swift:216`, `sACNSource.swift:215`, `sACNDiscoveryReceiver.swift:132`);
  `sACNReceiver`/`sACNReceiverGroup` use a separate `stateQueue`. This is a clean 1:1 map to actor isolation.
- The transport already runs on a NIO `EventLoop` and delivers up via `delegateQueue.async`
  (`NIOComponentSocket.swift:335-341`). Each socket currently grabs its own loop via
  `MultiThreadedEventLoopGroup.singleton.next()` (`:108`); for the shared-loop design this must become an
  injected loop.
- 5 GCD timer sites via `Vendor/CwlDispatch.swift`: source data-transmit ~44 fps (`sACNSource:727`) +
  discovery 10 s (`:704`); raw-receiver heartbeat 500 ms (`sACNReceiverRaw:462`) + sampling 1500 ms
  single-shot that re-arms (`:500`); discovery heartbeat 500 ms (`sACNDiscoveryReceiver:329`). The removal
  checklist for `CwlDispatch` is 3 symbols (`repeatingTimer`, `singleTimer`, `DispatchTimeInterval.interval`).
- `sACNReceiverRaw` uses generation tokens (`samplingGeneration`/`heartbeatGeneration`) to reject stale
  ticks; cooperative NIO task cancellation makes this unnecessary.
- `MonotonicTimer` (`Shared/MonotonicTimer.swift`) is a polled `Sendable` deadline read inside ticks, NOT a
  GCD timer and independent of CwlDispatch.
- 7 public delegate protocols + setters + `delegateQueue` on 5 components. All payload structs
  (`sACNReceiverMergedData`, `sACNReceiverSource`, `sACNReceiverRawSourceData`, `sACNDiscoveryReceiverSource`)
  are already `Sendable`; only socket-close `Error?` (`ComponentSocket.swift:123`) is not.
- Under Swift 6 (`complete`) there are **240 diagnostics** (raw 66, group 51, source 45, discovery 42,
  receiver 36), all non-`Sendable` self/delegate/`ComponentSocket` captures in the GCD `.async` closures.
  `Package.swift` today: `swiftLanguageModes: [.v5]`, `StrictConcurrency=targeted`, `.treatAllWarnings(as:.error)`.

## Architecture

### 1. Internal runtime abstraction (keeps NIO behind a seam)

Component actors depend on an **internal** `sACNRuntime` protocol, never on NIO types directly:

```swift
protocol sACNRuntime: Sendable {
    var serialExecutor: any SerialExecutor { get }                 // hosts the component actor
    func scheduleRepeated(after: Duration, every: Duration, _ body: @escaping @Sendable () -> Void) -> RuntimeTask
    func scheduleOnce(after: Duration, _ body: @escaping @Sendable () -> Void) -> RuntimeTask
    func makeSocket(type: ComponentSocketType, ipMode: sACNIPMode, port: UInt16) -> ComponentSocket
}
```

Each component actor holds `nonisolated let runtime`, derives `nonisolated var unownedExecutor` from
`runtime.serialExecutor`, schedules timers via `runtime.scheduleRepeated/Once`, and mints sockets via
`runtime.makeSocket`. The executor, timer scheduling, and sockets are **one matched serial context** - they
must be, or the synchronous hot-path delivery (below) breaks. NIO is confined to `NIORuntime`,
`NIOComponentSocket`, `NetworkInterfaceResolver`; actors/codec/streams stay NIO-free.

### 2. `NIORuntime` + NIO executor + transport (the only NIO-facing code)

- **`NIORuntime`** (new, `Shared/NIORuntime.swift`) wraps one shared `EventLoop`
  (`MultiThreadedEventLoopGroup.singleton.next()`); schedules timers on that loop via `scheduleTask`
  (self-rescheduling for fixed-rate repeats - see below). The `RuntimeTask` conformers own their chain
  with `[weak self]`, so a dropped handle deinit-cancels (cancel-on-deinit true by construction);
  `makeSocket` (added in PR2) returns a `NIOComponentSocket` bound to that loop.
- **Actor executor: a custom `EventLoopSerialExecutor`** (`Shared/EventLoopSerialExecutor.swift`) over the
  loop. `NIORuntime.serialExecutor` returns it; a component actor's `unownedExecutor` returns
  `runtime.serialExecutor.asUnownedSerialExecutor()`. PR1 briefly used `eventLoop.executor` instead (on the
  argument that `SelectableEventLoop` conforms to `NIOSerialEventLoopExecutor`), but PR2's loopback test
  proved that traps: NIO's `checkIsolated()` is `@available(macOS 15+)` in its precompiled module and,
  through the `any SerialExecutor` existential, resolves to the trapping stdlib default. The custom
  executor implements `checkIsolated()` directly (`preconditionInEventLoop`) and, being compiled at this
  package's macOS 15 floor, is unconditionally present. See the decision-1 delta above.
- Because the actor's executor **is** the loop, socket futures bridge to `await future.get()` (no `.wait()`,
  no thread block), and inbound packets from the channel handler (on that same loop) enter isolation
  **synchronously** via `actor.assumeIsolated { $0.process(...) }` - **zero Task spawns on the hot path**,
  FIFO preserved. Do **not** adopt `NIOAsyncChannel` (its back-pressured inbound would force a per-datagram
  `await` and break the synchronous parse -> merge path).
- **`NIOComponentSocket`**: take an **injected** `EventLoop` (stop calling `.next()` internally at `:108`);
  add `async` bind/close via `.get()` (the sync path is deleted in the final PR). Replace the close `Error?`
  (not `Sendable`) with `public struct SocketCloseReason: Error, Sendable { errnoCode: CInt?; message: String }`,
  built where `isFatal` classifies errno (`:404-411`). `SocketCloseReason` is public (it rides the public
  `events` streams) but is NIO-agnostic. **Behavior delta (PR2):** the internal close delegate now carries
  `SocketCloseReason`. `sACNSourceDelegate` was deleted with the source's actor conversion (PR2), so its
  close reason now rides the `events` stream as `.socketClosed(interface:reason:)`; the **receiver**
  delegates that remain keep their `socketDidCloseWithError: Error?` shape but the delivered value is now a
  `SocketCloseReason`, not the raw NIO `IOError` - a client that downcast the error sees a different type.
  Acceptable: those delegates are deleted as each receiver converts, and the async migration is the
  breaking major.

### 3. Timing - replace all 5 GCD timers via `runtime.scheduleRepeated/Once`

`NIORuntime` implements these on its `EventLoop`, **fixed-rate** (each occurrence scheduled at
`previousDeadline + interval`, matching the `DispatchSourceTimer` cadence, since NIO's own
`scheduleRepeatedTask` is fixed-*delay* and would droop the 44 fps transmit cadence under load). Ticks
land in-isolation (re-enter via `assumeIsolated`), deleting the `timerQueue` -> `socketDelegateQueue`
double-hop. Store the `RuntimeTask` handle to cancel.

| Timer | Site | Replacement |
|---|---|---|
| source data-transmit ~44 fps | `sACNSource.swift:727` | `scheduleRepeated` -> `sendDataMessages()` |
| source discovery 10 s | `:704` | send once inline in `start()`, then `scheduleRepeated` |
| raw heartbeat 500 ms | `sACNReceiverRaw.swift:462` | `scheduleRepeated` -> `checkForSourceLoss()` |
| raw sampling 1500 ms single-shot (re-arms) | `:500` | `scheduleOnce`; re-arm with a fresh `scheduleOnce` |
| discovery heartbeat 500 ms | `sACNDiscoveryReceiver.swift:329` | `scheduleRepeated` |

**Delete the generation-token guard** (`samplingGeneration`/`heartbeatGeneration` and all bump/validate
sites in `sACNReceiverRaw`): `.cancel()` runs on the same serial loop that fires ticks, so it
happens-before any not-yet-dequeued fire - no stale tick is possible. A cheap `guard lifecycle == .listening`
at each tick's top covers the one-already-in-flight case. **Keep `MonotonicTimer` unchanged** (polled
deadline; independent of CwlDispatch; converting to `ContinuousClock` buys nothing and re-derives all the
loss/PAP/discovery deadline math).

### 4. Reentrancy - reserve-before-await at the ~4 lifecycle sites

Hot paths (parse, merge, `buildDataMessages`, send) are synchronous within the actor and inherently safe.
Only lifecycle check-then-act sites suspend (socket bind via `.get()`):

- **Source** (`start`/`stop`/`updateInterfaces`): a `Lifecycle` enum (`idle/starting/listening/stopping`)
  set **synchronously before** the first `await`; a second `start()` sees `.starting` and throws; roll back
  to `.idle` on bind failure. `stop()` sets `.stopping` before awaiting close. **`start()` must treat a
  `CancellationError` from `socket.startListening()` as "superseded by an interleaving `stop`", not a
  failure**: roll the lifecycle back to `.idle` (already where `stop` left it) and do **not** emit an error
  onto the `events` stream - it is the expected outcome of a stop-during-start race, not a socket error.
- **Group `add(universe:)`** (`sACNReceiverGroup.swift:159-178`): a `starting: Set<UInt16>` reservation
  inserted before `await receiver.start()`, `defer`-removed; preserves "register only after successful
  start." `updateInterfaces` snapshots `Array(receivers.values)` before awaiting children.

### 5. Split-stream event model (`Shared/AsyncStreamHub.swift`, new)

`AsyncStream` is single-consumer, so a small **broadcast hub** (actor-isolated, `[UUID: Continuation]`,
`onTermination` cleanup) backs each stream; `data`/`events` are computed properties returning a fresh
subscribed stream. Buffering: **`data` = `.bufferingNewest(1)`** (a slow consumer gets the latest DMX
frame, matching DMX semantics); **`events`/discovery = `.bufferingNewest(64)`** (best-effort, drop-oldest,
documented). Yielding replaces every `delegateQueue.async { delegate?... }` site. Per-component `Event`
enums (all `Sendable`):

- `sACNReceiverRaw`: `data: AsyncStream<sACNReceiverRawSourceData>`; `Event` = samplingStarted/Ended,
  sourcesLost([UUID]), perAddressPriorityLost(UUID), sourceLimitExceeded, socketClosed(interface, reason).
- `sACNReceiver`: `data: AsyncStream<sACNReceiverMergedData>`; `Event` similar (no PAP-lost).
- `sACNReceiverGroup`: `data` (universe in payload); `Event` cases each tagged `universe: UInt16`.
- `sACNDiscoveryReceiver`: `discovery: AsyncStream<sACNDiscoveryReceiverSource>`; `Event` = sourcesLost, socketClosed.
- `sACNSource`: `events` only = transmissionStarted/Ended, socketClosed. Debug logging folds into a
  `.debug(String)` case on each `events` enum.

**Group child -> parent without delegates:** on `add`, spawn one consuming `Task` per child that drains the
child's `data`/`events` and re-yields into the group's hub (tagging the universe); cancel in
`remove`/`deinit`. This async-stream boundary replaces the synchronous sync-down/async-up delegate coupling
and is what lets the group be an ordinary actor.

### 6. `sACNMerger` isolation

**Keep it a non-`Sendable` `public class`** used only inside the `sACNReceiver` actor's isolation (its two
instances - live + sampling - become actor-stored properties; every merge call is isolated, no `await`).
Reject `public actor` (per-packet `await` overhead on the hottest path) and a `Sendable` value type (COW
churn on three 512-element arrays). For standalone public use, document "not thread-safe; serialize access"
(the contract it already carries at `sACNMerger.swift:37`). Legal under Swift 6 - it simply cannot cross
isolation boundaries, which is exactly the intended constraint.

## Staged PR sequence (each green under Swift 5 mode until PR5)

- **PR0 - Capture (docs only).** This document + a durable memory of the internal-`sACNRuntime` layering
  decision.
- **PR1 - Runtime seam (additive, internal).** New `sACNRuntime.swift` (protocol + `RuntimeTask`),
  `NIORuntime.swift` (**fixed-rate** `scheduleRepeated`/`scheduleOnce` with cancel-on-deinit for the
  repeated handle), `AsyncStreamHub.swift` (broadcast hub, buffering policy fixed per hub, terminal after
  `finish`). *Done.* (PR1 used `eventLoop.executor`; PR2 replaced it with a custom
  `EventLoopSerialExecutor` - see the decision-1 delta.) Deferred to PR2 (with their first consumer, the
  source actor): `NIOComponentSocket` async bind/close + injected loop + `SocketCloseReason`, and
  `runtime.makeSocket`.
- **PR2 - `sACNSource` -> actor.** *Done.* `events` stream (+ separate `debugLog` stream) and
  `isTransmitting`; removed `delegateQueue`/sentinel; two timers -> scheduled; deleted
  `Source/sACNSourceDelegate.swift`; added `Shared/EventLoopSerialExecutor.swift`.
  `buildDataMessages`/`sendDataMessages` (+ `terminate`, `emittedPacketSharesStorage` test seams) stay
  `internal` (tests call via `await`). Loopback tests migrated off the blocking semaphore to an async poll.
  **Lifecycle hardening (post-review):** reserve-before-await was completed across *every* mutating entry
  point via a `Lifecycle` enum (`idle/starting/listening/reconfiguring/stopping`), not just `start()` -
  `stop()` is now `async` and awaits the termination drain (continuation resumed at the `.idle`
  transition), a stop during `.starting`/`.reconfiguring` supersedes the in-flight op via the socket's
  epoch/`CancellationError` path, `updateInterfaces` reserves `.reconfiguring` and binds all-or-nothing
  (temp map, committed only if every bind succeeds), and `shouldOutput` is lifecycle-guarded so it cannot
  resurrect terminating universes mid-drain. `_isListening` was folded into `lifecycle` (one source of
  truth). `SourceLifecycleTests` is the gated regression net.
  **Second review pass (termination-mark model):** the `socketsShouldTerminate` bookkeeping was wholesale-
  overwritten in ways that corrupted each other in stop/reconfigure/removeUniverse overlap windows. Fixed
  as one change: `SourceUniverse.removeAfterTerminate` is now **sticky** (a stop's `terminate(remove:false)`
  cannot downgrade a `removeUniverse` mark); `stopDataTransmit` no longer populates `socketsShouldTerminate`
  (redundant - the universes' `shouldTerminate` drives termination); the quiescent/removal branches now
  actually *drop* marked sockets rather than only clearing the marks (and merged into one branch, fixing a
  `pendingSocketRemoval` strand); `updateInterfaces` is rejected while a prior socket-drain is pending
  (`.sourceBusy`) so a revert can't converge to zero sockets; and `sendDataMessages` now runs while
  `.reconfiguring` so keep-alives aren't starved during a slow bind. `shouldOutput(true)` resuming after a
  drain now re-emits `transmissionStarted` via a single `setTransmitting` owner (so `isTransmitting` never
  goes stale). **Finding 10b reversed and taken:** a full `buildDataMessages` trace confirmed the Bool was
  always homogeneous (the `.terminated` packet reaches every socket via `universeMessages` regardless), so
  `socketsShouldTerminate` is now `Set<String>` (membership = pending removal). Added `.sourceBusy` error
  and an `unownedExecutor` doc. (Only the per-packet hostname/`inet_pton` perf items remain deferred to the
  optional hot-path follow-up.)
- **PR3 - `sACNDiscoveryReceiver` -> actor.** *Done.* `discovery`+`events`+`debugLog` streams; heartbeat ->
  scheduled task; reserve-before-await `Lifecycle` (no drain - `stop()` awaits the socket close); internal
  `process(data:)` seam; added `sACNReceiverValidationError.receiverBusy`; deleted
  `sACNDiscoveryReceiverDelegate.swift`. **First actor-path socket *inbound* delivery** (channel handler on
  the loop -> `assumeIsolated { process(...) }`), validated by a gated end-to-end test (real source
  transmitting discovery -> `discovery` stream + `.sourcesLost`). New `DiscoveryReceiverTests` characterize
  the paged assembly via the seam; `sACNTestDiscoveryPacket` fixture added. De-risks PR4's inbound path.
  **Review pass:** fixed `process`'s typed catches (were logging `DataFraming`/`DMP` errors - dead here -
  instead of the `UniverseDiscovery{Framing,}LayerValidationError` this path actually throws, so parse
  errors reached `debugLog`); normalized a stop-superseded `start`/`updateInterfaces` to `CancellationError`
  (a mid-*join* abort otherwise surfaced a spurious `couldNotJoin`); `start` now throws `.receiverBusy` for
  transient states (matching `updateInterfaces`); nil the delegate before the fire-and-forget close on
  interface removal; scoped the `stop()` doc (only `.listening` awaits the close - supersede is
  fire-and-forget, rebind-safe via `SO_REUSEPORT`); removed dead `lastNotifiedUniverseCount` and `process`'s
  unused per-socket params; added loss-path (coalesce+remove) and malformed-packet tests; swept README/DocC.
- **Between PR3 and PR4 - extract a shared lifecycle gate.** The reserve-before-await machinery (the
  `Lifecycle` enum + `stopRequested`/`stopContinuations`/`reachedIdle` + the all-or-nothing interface diff)
  is now hand-copied in two actors and PR4 would copy it into three more. Extract it (e.g. a non-`Sendable`
  `LifecycleGate` held as actor state + a pure interface-diff helper; teardown stays per-component) and
  adopt it in `sACNSource` and `sACNDiscoveryReceiver` first, so the receiver vertical is written against
  the twice-debugged machinery. This also unifies the minor `start`-busy-signal inconsistency the source
  still carries.
- **PR4 - Receiver vertical (`sACNReceiverRaw` + `sACNReceiver` + `sACNReceiverGroup`) -> actors, one PR.**
  They are coupled by the sync-down/async-up contract (a GCD parent cannot synchronously drive an actor
  child, and the semaphore bridge is forbidden), so they convert together. `sACNMerger` unchanged. Replace
  raw's two timers + delete the generation tokens; wire per-child forwarding `Task`s; reserve-before-await
  in `group.add`. Internal seam (`process(data:)`, `beginSamplingPeriod`, `endedSamplingPeriod`,
  `checkForSourceLoss`) becomes `internal async`; tests swap `queue.sync { process(...) }` for
  `await process(...)`. Delete the 3 receiver delegate files.
- **PR5 - Swift 6 cutover.** `Package.swift` -> `swiftLanguageModes: [.v6]`, drop
  `StrictConcurrency=targeted`, keep `.treatAllWarnings(as:.error)`; delete `Vendor/CwlDispatch.swift`, the
  `DispatchSpecificKey` sentinels/`performOnStateQueue`, and the transitional sync bind/close. The 240
  `.v6` diagnostics should already be zero. Linux now compiles -> capture the Linux runtime baseline
  (`pre-phase-4-baseline.md`) and promote the Linux CI job back to blocking.

Dependency order: PR1 -> {PR2, PR3} -> PR4 -> PR5.

Optional follow-up (defer, not on the critical path): `RawSpan`/`InlineArray` hot-path adoption behind
`if #available` per the MODERNIZATION.md Phase 4 bullet; and the transmit send-loop micro-costs flagged in
the PR2 review (finding 10) - per-packet multicast-hostname `String` building + `inet_pton` re-parsing for
addresses fixed at `addUniverse`, and the redundant per-tick universe filters/`removeAll` - which are
pre-existing and orthogonal to the actor conversion. Cache the resolved `SocketAddress` per universe
rather than restringifying `239.255.x.x`/`ff18::...` each frame.

## Invariants to preserve

- **One-way delivery** becomes the async-stream boundary (children yield up; parents never block awaiting a
  parent) - no upward cycle.
- **Ordering:** one shared loop per coupled component group keeps cross-family + tick/packet order (stronger
  than today's two-queue hop).
- **Client reentrancy safety** (calling back in from a stream consumer) is automatic - consumers run on
  their own tasks, off the actor.
- **`deinit`** cannot run async: rely on `NIOComponentSocket.deinit`'s fire-and-forget channel close +
  finishing hub continuations + cancelling child `Task`s via `nonisolated` handles (there is no synchronous
  actor `stop()` to call from `deinit`).

## Risks / open questions

- **PR4 is unavoidably the one larger PR** (the receiver vertical converts together). Source and discovery
  remain genuinely independent single-component PRs. This is the honest reconciliation of decisions 1 and 3.
- **`assumeIsolated` correctness depends on `checkIsolated`, which is macOS 15 / iOS 18** - hence the floor
  raise. It is supplied by the custom `EventLoopSerialExecutor` (not `eventLoop.executor`, whose NIO
  `checkIsolated` is availability-gated in the precompiled module and degrades to the trapping stdlib
  default through the existential - see the decision-1 delta). The executor still requires a real loop with
  a running thread; an `EmbeddedEventLoop` is not usable, so test doubles must use a real loop.
- **Shared-loop fan-out:** many components pinning to one `.next()` loop can land on the same OS thread
  (matches today, where all sockets already use the singleton). Keep consumer work off the loop (consumers
  `for await` on their own tasks).
- **Stream back-pressure:** `.bufferingNewest(1)` on `data` silently drops frames under a stalled consumer
  (correct for DMX; documented). `events` is best-effort drop-oldest.

## Key files

- New (all internal): `Sources/sACNKit/Shared/sACNRuntime.swift` (protocol + `RuntimeTask`),
  `Shared/NIORuntime.swift`, `Shared/AsyncStreamHub.swift`.
- `Package.swift` platform floors raised to macOS 15 / iOS 18 / tvOS 18 / visionOS 2.
- `Sources/sACNKit/Shared/NIOComponentSocket.swift`, `Shared/ComponentSocket.swift` (inject loop, async I/O,
  `SocketCloseReason`).
- `Sources/sACNKit/Source/sACNSource.swift`; `Receiver/sACNReceiverRaw.swift`, `sACNReceiver.swift`,
  `sACNReceiverGroup.swift`, `sACNDiscoveryReceiver.swift` (-> actors + streams).
- Deleted: `Receiver/Delegate/**` (5 files), `Source/sACNSourceDelegate.swift`, delegate parts of
  `Shared/sACNComponent.swift`, `Vendor/CwlDispatch.swift`.
- `Package.swift` (final cutover). `sACNMerger.swift` unchanged.

## Verification

- **Every PR:** `swift build && swift test` green on macOS under Swift 5 mode; `swift format --strict` clean.
- **Characterization net survives:** the internal packet-injection seam is migrated (queue-sync ->
  `await`) each stage, keeping the receiver-state-machine, transmit-builder, merger, and layer suites as the
  regression guard. The reentrancy regression tests (`ReceiverGroupTests.callbacksMayReenterGroup`,
  `ReceiverRawTests.reentrantCallbackDoesNotDeadlock`, `ReceiverTests.informationFromCallback`) are rewritten
  to the stream model and must still pass.
- **Byte-identical transmit** (the Phase 3 golden tests) unchanged - the send path is untouched logic.
- **Loopback + TSan** gated suites (incl. the IPv6 test) green on macOS; TSan clean over the new
  executor/stream paths.
- **PR5:** green under Swift 6 language mode; the 240 complete-mode diagnostics are 0; Linux `Build & Test`
  now compiles and passes -> fill the `pre-phase-4-baseline.md` Linux column (R5 evidence).
