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
  `DispatchSpecificKey` sentinel + `stateQueue.sync`). The state queue must never target the
  client's queue (see deadlock notes below).
- **Lock hierarchy (the rule): `sync` flows parent -> child only; child -> parent is always
  `.async`.** A parent may `sync` down into its children (the group's `information(for:on:)`,
  `updateInterfaces` and `add` do), but a child delivers up to its parent exclusively with `.async`
  hops. Never `sync` upward or sideways between components - the one-way direction is what makes
  the downward `sync` deadlock-free. Be aware `add`/`start` performs socket I/O while holding the
  group `stateQueue`, which is also the delivery conduit for every universe's callbacks, so keep
  work held on that queue short.
- Public getters read state via `.sync` onto the owning queue (e.g. `isListening`).
- Timers run on separate static/instance `timerQueue`s; timeout math uses `MonotonicTimer` (a struct).
  Timer ticks hop to the owning queue and are validated against a **generation token** before acting;
  the token must be bumped at **every** install and teardown site (see `samplingGeneration` in
  `sACNReceiverRaw`) - a timer installed without a bump silently reopens the stale-tick window.

## Event-loop tier (SwiftNIO transport, Phase 3)

- The transport is `NIOComponentSocket` (SwiftNIO). Each facade owns up to two datagram channels
  (one per address family) bound on a **single shared event loop**, so cross-family callback order
  matches the total order the old shared GCD socket queue gave. **Event loops sit strictly *below*
  every component queue in the lock hierarchy.**
- Delivery is `.async`-only and upward: a channel handler runs on the event loop, captures the
  payload, then `delegateQueue.async` hops onto the owner's `socketDelegateQueue` and reads the
  (weak) delegate **inside** that hop - exactly where `GCDAsyncUdpSocket` delivered. Never call a
  delegate directly from the event loop.
- **`.wait()` on a NIO future is permitted only from a GCD queue, never from an event loop or a
  channel handler.** `startListening`/`stopListening` run `bind().wait()` / `close().wait()` on the
  owner's `socketDelegateQueue`; this cannot deadlock because an event loop never blocks on, syncs
  to, or waits for any GCD queue, so a GCD queue blocking down on an event-loop future closes no
  cycle. Blocking a NIO thread on a GCD queue would break this and is forbidden.
- `NIOComponentSocket` is `@unchecked Sendable`: all mutable state lives in one `NIOLockedValueBox`
  and the delegate reference is weak (an owner holds its socket strongly and sets `socket.delegate =
  self`, so a strong reference would leak the component and defeat close-on-dealloc). Keep both
  invariants when touching it.

## Delegate delivery
- **Every** delegate callback is delivered **asynchronously** on the caller-supplied `delegateQueue`:
  capture the delegate on the owning queue, then `delegateQueue.async { delegate?.… }`
  (capture-before-hop). Never add synchronous cross-queue delivery, and never invoke a delegate
  directly from the owning queue.
- Ordering is preserved per component: deliveries are enqueued FIFO from a serial queue.
- All `delegate` references are `weak`; timer closures capture `[weak self]`. Preserve both to avoid
  retain cycles.
- **Async delivery contracts** (consequences of the Phase 2 sync -> async flip; the real fix is the
  Phase 4 actor redesign - do not add stopgap fences):
  - `stop()` is not a delivery barrier: callbacks already enqueued may fire after it returns.
  - `setDelegate(nil)` does not fence in-flight deliveries: a callback enqueued earlier holds a
    strong reference to the previous delegate and may still fire on it.
  - `information(for:)` reflects current state, not a callback payload's snapshot: it may throw for
    a CID a just-delivered payload listed as active.

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
- The sentinel keys are **static per-type**, so they answer "am I on ANY instance's queue of this
  type?", not "this instance's". No current path crosses instances; the first cross-instance
  feature (e.g. one receiver calling into another from a callback) would silently run
  unsynchronized instead of deadlocking loudly. Switch to per-instance keys if that ever lands.

## Delegate contract (callers)
- A **serial** `delegateQueue` is still recommended (callback ordering), but internal state is
  serialized on internal queues, so a concurrent queue no longer corrupts state.
- `information(for:)` may be called from any queue, including from within delegate callbacks.

## When modernizing (Phase 4)
- The value model is `Sendable` (Phase 2). Next: convert components to actors and replace the
  queue-as-mutex + delegate delivery with `async`/`AsyncStream`. The strict-concurrency recon
  inventory in docs/modernization/phase-2.md lists the diagnostics Swift 6 mode must resolve.
