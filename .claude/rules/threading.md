# Threading & concurrency contract (current, pre-modernization)

The library has **no Swift Concurrency yet**; it uses GCD serial queues + weak delegates. This will be
replaced by an actor/`async` model (@MODERNIZATION.md Phases 2 & 4). Until then, these contracts hold
and must be respected when touching the code.

## Queue model
- Each component (`sACNSource`, `sACNReceiverRaw`, `sACNReceiver`, `sACNDiscoveryReceiver`) owns a
  **`socketDelegateQueue`** (serial) that both receives socket callbacks **and doubles as the state
  mutex**; nearly all private mutable state is only touched inside `socketDelegateQueue.sync { ... }`.
  When adding state or methods, keep that invariant: mutate state only on that queue.
- Public getters read state via `socketDelegateQueue.sync { _value }` (e.g. `isListening`).
- Timers run on separate static/instance `timerQueue`s; timeout math uses `MonotonicTimer`.

## Reentrancy / deadlock (important)
- Self-reentrancy is handled with a `DispatchSpecificKey` sentinel: methods like `stop()` detect
  "am I already on `socketDelegateQueue`?" and call the `_impl` directly instead of `.sync`
  (avoids the deinit -> stop -> sync self-deadlock; cf. commit `67e3e2b`). **Reuse this pattern** for
  any new method callable both externally and from within the queue.
- **Known hazard:** `sACNReceiverRaw.processDataPacket` delivers to the delegate via
  `delegateQueue.sync` **while holding `socketDelegateQueue`**. A client that calls back into the
  receiver from inside a delegate callback can AB/BA deadlock. (The transmit side uses
  `delegateQueue.async`, which is safe; the inconsistency is receiver-only.) Closing this is a Phase 2
  item; don't add new synchronous cross-queue delivery.

## Delegate contract (callers)
- The caller-supplied **`delegateQueue` must be serial.** `sACNReceiver`/`sACNReceiverGroup` keep no
  lock of their own; their state is safe *only* because callbacks are serialized on that queue. A
  concurrent queue races the `sources` dict / counters. This is currently under-documented; treat it as
  a hard requirement.
- Delegate methods are invoked **synchronously** on the receive side and "should be handled quickly"
  (don't block; don't re-enter the component, per the hazard above).
- All `delegate` references are `weak`; timer closures capture `[weak self]`. Preserve both to avoid
  retain cycles.

## When modernizing (Phases 2/4)
- Make value-type DTOs/models `Sendable` first (Phase 2), then convert components to actors and replace
  the queue-as-mutex + delegate delivery with `async`/`AsyncStream` (Phase 4). See @MODERNIZATION.md.
