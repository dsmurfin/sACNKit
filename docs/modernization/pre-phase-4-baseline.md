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

Updated for the Linux runtime column as of **Phase 4 PR5** (Swift 6 mode; `CwlDispatch` deleted): the Linux
build now compiles and the runtime baseline is captured (see "Linux runtime baseline" below).

| Area | macOS local | macOS CI | Linux CI | Linux runtime |
|---|---|---|---|---|
| Logic net (145) | green | **blocking, green** | **blocking, green (PR5)** | **green (145, PR5)** |
| Socket facade (bind/join/errors/re-listen/dealloc) | green | gated, non-blocking | non-blocking | **green (PR5, container)** |
| IPv4 multicast delivery | green | gated, non-blocking (unreliable on shared runners) | non-blocking | **green (PR5, container)** |
| **IPv6 multicast delivery / `IPV6_MULTICAST_IF` egress** | **green** | gated, non-blocking | non-blocking | **container join fails (R5\*)** |
| TSan over network | green (local) | gated, non-blocking | not run | not run |

\* **IPv6 multicast is an environment limit, not a code regression.** In the `swift:6.2-noble` container the
IPv6 multicast *join* fails (`couldNotJoin ff18::…`) because the container has no IPv6 multicast loopback; the
IPv4 control (unicast + IPv4 multicast delivery + IPv4 end-to-end loopback) all pass on Linux, so R5's IPv4
egress is confirmed and only IPv6 egress remains gated on a Linux environment with working IPv6 multicast.
The former block ("the Linux build does not compile") is resolved by PR5: the actor redesign removed the
concurrency-capture diagnostics and `CwlDispatch` (with its Darwin-only symbols) is deleted.

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
4. **(Resolved in PR5)** The Linux `Build & Test` job was non-blocking and did not build (two
   Phase-4-dissolved causes: concurrency captures, `CwlDispatch` Darwin symbols). PR5 deletes `CwlDispatch`
   and the captures are gone with the actor rewrite, so the Linux build now compiles; the job is promoted to
   blocking.

## Linux runtime baseline (captured in Phase 4 PR5)

Captured on the `swift:6.2-noble` container (Swift 6.2.4, `aarch64-unknown-linux-gnu`) via
`docker run --rm -v "$PWD":/pkg -w /pkg swift:6.2-noble ...`:

- **Ungated logic net:** `swift build --build-tests && swift test` compiles and **passes (145 tests)** on
  Linux - the primary PR5 outcome (the Linux build was the blocker). This is now the blocking `linux`
  CI job.
- **Gated suites** (`SACNKIT_NETWORK_TESTS=1 swift test --filter
  "LoopbackTests|ReceiverGroupTests|NIOComponentSocketTests"`):
  - **IPv4 pass:** socket facade (bind / reuse-port / join+leave / unicast delivery / **IPv4 multicast
    delivery** / re-listen / dealloc), the IPv4 source->receiver and source->group end-to-end loopbacks, and
    the discovery loopback all pass. **R5 evidence: IPv4 multicast egress works on Linux** (the unicast
    control passes *and* IPv4 multicast delivery/egress passes), so the pre-committed R5 fallback
    (`IP_MULTICAST_IF` on v4 transmit) is **not** needed.
  - **IPv6 fail (environment):** `sourceToReceiverIPv6` fails at the multicast *join*
    (`couldNotJoin ff18::…`) because the container has no IPv6 multicast loopback. This is an environment
    limit, not a code regression; IPv6 egress (R5) remains gated on a Linux environment with working IPv6
    multicast. The network suites therefore stay in the **non-blocking** `linux-loopback` job.

Re-run the gated suites in a Linux environment with multicast loopback configured (a container with
`NET_ADMIN` + a multicast route, a local VM, or a self-hosted runner) to also cover IPv6 egress.
