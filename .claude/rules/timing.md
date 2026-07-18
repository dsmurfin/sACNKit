# sACN timing constants & suppression model

The protocol is timing-sensitive; these are the intervals the code uses today, with source locations.
Treat them as the current baseline. Some are targeted for change in MODERNIZATION.md Phase 5 (e.g. a
separately-configurable PAP keep-alive to match ETC), so verify against source before relying on a value.

## Transmit (source)
- **Data frame rate: ~44 fps**, `dataTransmitInterval = 1/44 s` (~22.7 ms) (`Source/sACNSource.swift`).
- **Universe discovery interval: 10 s** (`Source/sACNSource.swift`, `universeDiscoveryInterval`).
- **Change burst ("3 packets on change"):** any level/priority/config change sets `dirtyCounter = 3`,
  so the change is sent on 3 consecutive frames before suppression resumes (`Source/SourceUniverse.swift`).
- **Keep-alive (suppressed) cadence:** `transmitCounter` cycles `0...42` (resets after >42, ~1 s at
  44 fps); NULL levels are force-sent at counter `0, 11, 22, 33` (~every 250 ms), and PAP (`0xDD`) is
  sent at counter `0` (~once/s). See the `switch universe.transmitCounter` in `Source/sACNSource.swift`.
  (ETC uses ~800 ms NULL / ~1000 ms PAP keep-alive; aligning these is a Phase 5 item.)
- **Termination:** `markTerminated()` sets `dirtyCounter = 3`, giving 3 packets with the `terminated`
  option bit set, then the stream stops (E1.31 requires 3 termination packets).

## Receive (receiver)
- **Network data-loss timeout: 2500 ms**, `sACNReceiverRaw.sourceLossTimeout` (Universal Hold Last
  Look). A source silent this long is considered lost.
- **Sampling period: 1500 ms**, `sampleTime` (single-shot). During sampling, valid data notifies
  regardless of start code; anti-flicker on discovery.
- **New-source PAP wait: 1500 ms**, `perAddressPriorityWait`. A new source's levels are held this long
  awaiting a `0xDD` packet before falling back to universe priority.
- **Receiver heartbeat: 500 ms**, `sACNReceiverRaw.heartbeatInterval` (drives timeout evaluation).
- **Discovery receiver heartbeat: 500 ms** (`Receiver/sACNDiscoveryReceiver.swift`; the discovery receiver
  is now an actor (PR3), so this runs on a NIO scheduled task via `sACNRuntime`, not `CwlDispatch`).

## Clock
- Timeouts use `Shared/MonotonicTimer.swift` (monotonic, immune to wall-clock changes). It is
  cross-platform (Phase 1): `#if canImport(Darwin)` uses `clock_gettime_nsec_np(CLOCK_UPTIME_RAW)`,
  otherwise `clock_gettime(CLOCK_MONOTONIC)` on Glibc. `isExpired` uses strict `>`, and `interval == 0`
  means "already expired" (used to force immediate expiry, e.g. on termination).
- **Every component actor's** timers now run on **NIO scheduled tasks** via `sACNRuntime` (Phase 4),
  ticking in-isolation: `scheduleRepeated` (fixed-rate, coalescing) for the source transmit / discovery /
  receiver heartbeats, and `scheduleOnce` for `sACNReceiverRaw`'s single-shot, self-re-arming sampling
  timer (`sampleTask`). Ticks guard before acting - the heartbeat on `gate.isListening`, the sample tick on
  the `sampling` flag (which `teardown` clears) - so a tick that raced a stop cannot act or re-arm; the old
  GCD generation tokens are gone. `Vendor/CwlDispatch.swift` is now unreferenced (deleted in PR5). The
  constants above are unchanged - only the timer mechanism moved.
