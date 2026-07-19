# sACN timing constants & suppression model

The protocol is timing-sensitive; these are the intervals the code uses today, with source locations.
Treat them as the current baseline. Some are targeted for change in MODERNIZATION.md Phase 5 (e.g. a
separately-configurable PAP keep-alive to match ETC), so verify against source before relying on a value.

## Transmit (source)
- **Data frame rate: ~44 fps**, `dataTransmitInterval = 1/44 s` (~22.7 ms) (`Source/sACNSource.swift`).
- **Universe discovery interval: 10 s** (`Source/sACNSource.swift`, `universeDiscoveryInterval`).
- **Change burst ("3 packets on change"):** any level/priority/config change sets `dirtyCounter = 3`,
  so the change is sent on 3 consecutive frames before suppression resumes (`Source/SourceUniverse.swift`).
- **Keep-alive (suppressed) cadence:** separately configurable NULL and PAP keep-alive intervals, defaulting
  to **800 ms NULL / 1000 ms PAP** (matching ETC; Phase 5 PR4), set via `sACNSource(nullKeepAliveInterval:
  perAddressPriorityKeepAliveInterval:)`. Each is converted once to a whole number of ~44 fps transmit ticks
  (`sACNSource.nullKeepAliveTicks`/`papKeepAliveTicks`, clamped to at least 1) and driven per-universe by the
  `SourceUniverse.ticksSinceLevels`/`ticksSincePriorities` counters (reset on the respective send) in
  `buildDataMessages`. Keep the interval below the 2500 ms data-loss timeout so receivers do not consider the
  source lost. (Replaced the old fixed `transmitCounter` cadence of ~250 ms NULL / ~1 s PAP.)
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
  GCD generation tokens (and the vendored `CwlDispatch` timers) are gone. The constants above are unchanged -
  only the timer mechanism moved.
