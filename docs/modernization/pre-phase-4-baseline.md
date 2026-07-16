# Pre-Phase-4 Test Baseline (Phase 3 completion)

## Purpose

Phase 4 rewrites exactly the layer Phase 3 built - timing (`CwlDispatch` removal), delivery (delegates
-> `AsyncStream`), and isolation (queue-as-mutex -> actors). This document captures a known-good
baseline of the current suites so the Phase 4 rewrite has a concrete regression reference, and records
- in writing - the coverage that is deliberately accepted as unverified going in. It is the seed record
for Phase 4 alongside the MODERNIZATION.md Phase 3 Status note.

## How to reproduce

- **Blocking logic net** (gates merges): `swift test` on macOS. ~110 non-network tests (layers, merger,
  receiver state machine via the `process(data:)` seam, transmit builder, `MonotonicTimer`).
- **Gated network suites** (opt-in, non-blocking): `SACNKIT_NETWORK_TESTS=1 swift test --filter
  "LoopbackTests|ReceiverGroupTests|NIOComponentSocketTests"`. Exercises the real NIO socket facade:
  bind/join/leave, reuse-port dual bind, typed bogus-interface errors, stop/start re-listen,
  deallocation, unicast + multicast delivery, and end-to-end v4 **and v6** loopback merge.
- **Thread sanitizer**: `swift test --sanitize=thread` (macOS); loopback-under-TSan is a separate gated,
  non-blocking job.
- **Benchmark trend** (non-blocking): `SACNKIT_BENCH=1 swift test --filter "PerformanceBenchmarks"`.

## Baseline result - macOS (Swift 6.2 toolchain / Xcode 26), captured 2026-07-16

| Suite | Gate | Result |
|---|---|---|
| Logic net (`swift test`) | blocking | green (~110 tests) |
| `LoopbackTests` (v4 + v6 merge) | `SACNKIT_NETWORK_TESTS=1` | green (v6 test stable over repeated runs) |
| `ReceiverGroupTests` | `SACNKIT_NETWORK_TESTS=1` | green |
| `NIOComponentSocketTests` (bind/join/reuse-port/errors/re-listen/dealloc/delivery) | `SACNKIT_NETWORK_TESTS=1` | green |
| TSan (logic + shared code) | blocking | green |
| `PerformanceBenchmarks` allocation guard | blocking | green |

## Coverage matrix (what is green, where)

| Area | macOS local | macOS CI | Linux CI | Linux runtime |
|---|---|---|---|---|
| Logic net (110) | green | **blocking, green** | non-blocking (fails to build) | blocked* |
| Socket facade (bind/join/errors/re-listen/dealloc) | green | gated, non-blocking | non-blocking | blocked* |
| IPv4 multicast delivery | green | gated, non-blocking (unreliable on shared runners) | non-blocking | blocked* |
| **IPv6 multicast delivery / `IPV6_MULTICAST_IF` egress** | **green (new)** | gated, non-blocking | non-blocking | **blocked* (R5)** |
| TSan over network | green (local) | gated, non-blocking | not run | blocked* |

\* **The Linux runtime column is blocked on the Linux build compiling, not on hardware.** Today
`swift build` fails on Linux (concurrency-capture diagnostics + `CwlDispatch` Darwin symbols), so no
test binary is produced and **no Linux environment - container, VM, self-hosted runner, or bare metal -
can run these suites yet.** That build is a Phase 4 outcome (the actor redesign removes the captures;
`CwlDispatch` is deleted), unless deliberate throwaway portability patches are applied first (`import
Glibc` for `NSEC_*`, plus quieting the captures) purely to produce a test binary. See the Linux runtime
baseline section below.

## Risks explicitly accepted before Phase 4

These are known-uncovered and accepted as-is going into Phase 4 (recorded here rather than left implicit):

1. **IPv6 is validated only on macOS loopback.** `LoopbackTests.sourceToReceiverIPv6` runtime-validates
   the `IPV6_MULTICAST_IF` egress and end-to-end v6 send/receive on Darwin, but it is non-blocking (v6
   multicast loopback is unreliable on shared CI runners). `IPV6_V6ONLY` family separation and `withPort`
   scope-id preservation for link-local binds remain CI-unverified. Phase 4 keeps the NIO transport, so
   this path is inherited as-is.
2. **Linux IPv4 multicast egress is untested (risk R5).** The `CInt`/`Int` compile fix landed, but no
   Linux runtime run has confirmed egress (and none is possible until the Linux build compiles - see
   below). If a Linux run shows v4 multicast egress failing while the unicast control test passes, set
   `IP_MULTICAST_IF` on v4 transmit channels (the pre-committed R5 decision rule). This is the one item
   where an environment with a realistic network stack matters (route-table egress behavior) - a local
   VM or self-hosted runner suffices; dedicated bare metal is not required.
3. **Multicast delivery does not run on shared CI runners.** Delivery assertions are exercised locally
   only; CI validates bind/join/config, not datagram arrival.
4. **The Linux `Build & Test` job is non-blocking and does not build** (two Phase-4-dissolved causes:
   concurrency captures, `CwlDispatch` Darwin symbols). See the MODERNIZATION.md Phase 3 Status note.

## Linux runtime baseline (gated on the Linux build, i.e. Phase 4)

This cannot be captured today: the Linux build does not compile (see the note under the coverage
matrix), so there is no test binary to run - on any hardware. It becomes possible once the Linux build
is green, which is a Phase 4 outcome (the actor redesign removes the concurrency captures and deletes
`CwlDispatch`) - or requires deliberate throwaway portability patches applied purely to produce a test
binary. It is therefore a Phase-4-era step, not a pre-Phase-4 one.

When the Linux build compiles, run the gated suites in any Linux environment where multicast loopback is
configured - a container with `NET_ADMIN` plus a multicast route (`ip route add 224.0.0.0/4 dev lo`, and
the IPv6 equivalent), a local VM, or a self-hosted runner. A locked-down *shared* CI runner is the only
environment ruled out; dedicated bare metal is **not** required.

```
SACNKIT_NETWORK_TESTS=1 swift test --filter "LoopbackTests|ReceiverGroupTests|NIOComponentSocketTests"
```

Record the outcome in the "Linux runtime" column above. This establishes the Linux runtime baseline and
produces the R5 evidence (unicast control vs v4 multicast egress). Until then, Linux runtime behavior is
untested, not confirmed.
