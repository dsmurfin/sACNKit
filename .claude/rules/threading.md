# Threading & concurrency contract (current, post-Phase 2)

The library has **no Swift Concurrency API yet**; it uses GCD serial queues + weak delegates, with
`StrictConcurrency=targeted` checking staged in `Package.swift` (warning-clean; CI builds with
warnings-as-errors). The actor/`async` model lands in Phase 4 (MODERNIZATION.md). Until then, these
contracts hold and must be respected when touching the code.

## Queue model
- Each socket-owning component (`sACNSource`, `sACNReceiverRaw`, `sACNDiscoveryReceiver`) owns a
  **`socketDelegateQueue`** (serial) that both receives socket callbacks **and doubles as the state
  mutex**; nearly all private mutable state - including the `delegate`/`debugDelegate` references -
  is only touched on that queue. When adding state or methods, keep that invariant.
- `sACNReceiver` and `sACNReceiverGroup` each own a private serial **`stateQueue`** guarding their
  state (`sources`, mergers, `receivers`); public API uses `performOnStateQueue` (a
  `DispatchSpecificKey` sentinel + `stateQueue.sync`). The state queue must **never target the
  client's queue and never `sync` onto another component's queue** - deliveries hop with `.async`
  only (see deadlock notes below).
- Public getters read state via `.sync` onto the owning queue (e.g. `isListening`).
- Timers run on separate static/instance `timerQueue`s; timeout math uses `MonotonicTimer` (a struct).

## Delegate delivery
- **Every** delegate callback is delivered **asynchronously** on the caller-supplied `delegateQueue`:
  capture the delegate on the owning queue, then `delegateQueue.async { delegate?.… }`
  (capture-before-hop). Never add synchronous cross-queue delivery, and never invoke a delegate
  directly from the owning queue.
- Ordering is preserved per component: deliveries are enqueued FIFO from a serial queue.
- All `delegate` references are `weak`; timer closures capture `[weak self]`. Preserve both to avoid
  retain cycles.

## Reentrancy / deadlock (important)
- Self-reentrancy is handled with a `DispatchSpecificKey` sentinel: methods like `stop()` and the
  delegate setters detect "am I already on the owning queue?" and run directly instead of `.sync`
  (avoids the deinit -> stop -> sync self-deadlock; cf. commit `67e3e2b`). **Reuse this pattern** for
  any new method callable both externally and from within the queue.
- **Do not create a serial queue that targets a client-supplied queue and then `sync` onto it from
  the target's context** - GCD's deadlock detection traps (`_dispatch_sync_f_slow`, SIGTRAP). This
  was attempted for the Phase 2 state queues and rejected; see docs/modernization/phase-2.md
  completion notes.
- Clients may safely call back into a component (including `stop()`, `setDelegate`, `information`)
  from within delegate callbacks; regression tests cover this. Do not reintroduce `.sync` deliveries
  that would break it.

## Delegate contract (callers)
- A **serial** `delegateQueue` is still recommended (callback ordering), but internal state is
  serialized on internal queues, so a concurrent queue no longer corrupts state.
- `information(for:)` may be called from any queue, including from within delegate callbacks.

## When modernizing (Phase 4)
- The value model is `Sendable` (Phase 2). Next: convert components to actors and replace the
  queue-as-mutex + delegate delivery with `async`/`AsyncStream`. The strict-concurrency recon
  inventory in docs/modernization/phase-2.md lists the diagnostics Swift 6 mode must resolve.
