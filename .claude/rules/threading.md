# Threading & concurrency contract (current, Phase 4)

Every component is now a Swift **`actor`** - `sACNSource` (PR2), `sACNDiscoveryReceiver` (PR3), and the
receiver vertical `sACNReceiverRaw` / `sACNReceiver` / `sACNReceiverGroup` (PR4). No GCD queues, weak
delegates, `DispatchSpecificKey` sentinels, or `CwlDispatch` timers remain. `StrictConcurrency=targeted`
checks in `Package.swift` (warning-clean; CI builds with warnings-as-errors). The Swift 6 language-mode
flip and the `Vendor/CwlDispatch.swift` deletion are the remaining Phase 4 item (PR5).

## Actor isolation model
- Each actor is pinned to an `sACNRuntime` (a shared NIO event loop) via a custom `EventLoopSerialExecutor`
  returned from `unownedExecutor`. So the actor's isolation **is** its event loop: the transport delivers
  inbound packets into the actor with no `Task` hop (a `nonisolated` `ComponentSocketDelegate` method
  `assumeIsolated`s into the actor because it already runs on that loop), and the actor's timers
  (`sACNRuntime.scheduleRepeated`/`scheduleOnce`) tick in-isolation.
- All mutable state is actor-isolated: mutate it only from within the actor. There is no queue-as-mutex and
  no manual locking of component state (the one lock left is inside `AsyncStreamHub`, guarding its
  subscriber list, and `NIOComponentSocket`'s `NIOLockedValueBox` - both below the component tier).

## Lifecycle: the shared `LifecycleGate` (reserve-before-await)
- Each actor holds a `private var gate = LifecycleGate()` (`Shared/LifecycleGate.swift`) - a non-`Sendable`
  struct state machine (`idle`/`starting`/`listening`/`reconfiguring`/`stopping`). Because actor reentrancy
  can interleave other calls at every `await`, `start`/`stop`/`updateInterfaces` **reserve their transition
  synchronously (before the first `await`)**: `reserveStart()`/`reserveReconfigure()` classify the entry and
  flip state atomically, so a concurrent double-start or a stop-during-start is detected, not raced. Map the
  gate's `.busy`/`.alreadyActive` results to the component's own error type.
- `stop()` registers a continuation via `addStopWaiter` and awaits socket close; teardown calls
  `reachedIdle()` (which drains and resumes all waiters in one isolated mutation, so a continuation can
  never be resumed twice). A stop that supersedes an in-flight start/reconfigure sets `requestStop()`; the
  in-flight operation observes `stopRequested` and unwinds. `updateInterfaces` binds all-or-nothing into a
  temp map and only commits if every bind succeeds.
- **`deinit` cannot stop** (it can't `await`): teardown on drop relies on socket dealloc-close, hub
  `finish()`, and timer/`Task` self-cancellation. Prefer an explicit `await stop()`.

## Raw -> merged: the on-loop synchronous sink (load-bearing)
- `sACNReceiver` (merged) owns its `sACNReceiverRaw` on the **same** `sACNRuntime`/event loop (it constructs
  the raw via the injected-runtime init with `runtime: self.runtime`). Both actors therefore return the same
  `EventLoopSerialExecutor`.
- The raw delivers into the merge **synchronously, on the loop**, via the `RawReceiverSink` protocol: merged
  conforms with `nonisolated` methods that `assumeIsolated { $0.mergeData(...) }`. This is valid **only**
  because the two share one executor (`assumeIsolated`'s `checkIsolated()` verifies the loop, not the
  instance). A different runtime for the raw would trap - this is the single most important correctness
  invariant of the receiver vertical. The merge stays one serialized per-packet chain (no `Task` hop, no
  reordering of `data` vs `events`).
- The raw has a **dual outlet**: each emit site (`emit(data:)`, `emit(_:Event)`, `log(_:)`) both yields to
  its own public hub (for standalone `sACNReceiverRaw` users) **and** calls the optional `weak rawSink`
  (for the embedding merged receiver). One producer, two disjoint sinks, decided at the emit boundary.

## Group -> children: async-up `Task` fan-in
- `sACNReceiverGroup` is an actor with its own runtime; each child `sACNReceiver` owns a separate runtime -
  a distinct executor and isolation (the underlying event loops come from the shared singleton group and may
  coincide, which the async fan-in tolerates; unlike raw+merged, the group and its children never share one
  runtime). On `add`, the group spawns **one drain `Task` per child stream** (`data`/`events`/`debugLog`) that
  `for await`s the child's stream and re-yields into the group's hubs (tagging the universe). This is a
  one-way async fan-in: a group of actors never synchronously drives an actor child (which would require
  `await` inside a non-async context). The three structural mutations - `add`/`remove`/`updateInterfaces` -
  are serialized through an async mutation lock (`beginMutation()`/`endMutation()` + a waiter FIFO), which
  restores the old serialized group's one-at-a-time guarantee across the actor's suspension points, so
  concurrent mutations cannot interleave into inconsistent child/interface state. Within `add`, the drain
  `Task`s are **subscribed before `await child.start()`** (so the child's synchronous `.samplingStarted`
  emitted during start is not lost), then `children[universe]` is registered **only after** start succeeds
  (on a throw the subscription's `Task`s are cancelled); `remove` cancels the drain `Task`s and drops the
  child (closing its sockets on dealloc). The drain `Task`s capture the child's **stream** (not the child)
  and `[weak self]`, so they neither retain the child nor cycle; they end when the child's stream finishes.

## Output streams (`AsyncStream` via `AsyncStreamHub`)
- Each actor exposes `data`/`events`/`debugLog` as `nonisolated` computed properties backed by an
  `AsyncStreamHub` (broadcast fan-out; multiple consumers allowed). Buffering is component-specific:
  `events`/`debugLog` (and discovery's `discovery`) buffer `.bufferingNewest(64)`; **merged/group `data`
  buffers `.bufferingNewest(1)`** (each frame is a complete DMX snapshot, so a slow consumer gets the latest,
  not a stale backlog); **`sACNReceiverRaw`'s `data` buffers `.bufferingNewest(64)`** (it interleaves frames
  from distinct sources, which must not collapse into one another). All are drop-oldest for a stalled
  consumer, so a long-stalled `events` consumer can miss an event such as `.sourcesLost`.
- Consequences of stream (vs delegate) delivery - do not add stopgap fences:
  - `stop()` is not a delivery barrier: elements already yielded may still be observed after it returns.
  - `information(for:)` reflects current state, not a payload snapshot: it may throw for a source a
    just-delivered payload listed as active.
- Reentrancy is now automatic: stream consumers run **off-actor**, so a consumer may freely call back into
  the component (`stop`, `information`, `add`, `remove`) from within a `for await` body without deadlock.
  Regression tests cover this for the raw receiver and the group.

## NIO transport tier (below the actors)
- The transport is `NIOComponentSocket` (SwiftNIO), `@unchecked Sendable`: all mutable state lives in one
  `NIOLockedValueBox`, and the delegate reference is **weak** (an owner holds its socket strongly and sets
  `socket.delegate = self`; a strong reference would leak the component and defeat close-on-dealloc). Keep
  both invariants when touching it.
- Sockets come from `sACNRuntime.makeSocket`; the channel handler runs on the actor's event loop and calls
  the (nonisolated) `ComponentSocketDelegate` method, which `assumeIsolated`s into the actor - same serial
  context, no cross-context hop. `startListening`/`stopListening` are `async` and await the NIO
  bind/close futures from within the actor; never block an event loop thread.
- Scope note: "no delegates remain" is true at the **component** tier. `NIOComponentSocket` still carries a
  legacy GCD `delegateQueue` delivery path (async hop onto a caller queue + the blocking `.wait()`
  bind/close) from the pre-actor components. No component uses it now - every owner takes the actor / loop
  path - so it is dead in production and exercised only by `NIOComponentSocketTests`. It is removed in PR5
  with `CwlDispatch` and the Swift 6 flip.
