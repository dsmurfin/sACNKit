# sACNKit Modernization - Phase 3: SwiftNIO Transport Migration (Detailed Plan)

> **Status: complete** - PR 1 (transport swap) + PR 2 (transmit allocation win) merged as #43. The
> honest-history outcomes (behavior deltas B-1..B-3 shipped; **R6 resolved** via `@unchecked Sendable`;
> **R5 open** - Linux IPv4 multicast egress untested; the broader `isFatal` errno set; and the
> **non-blocking, known-not-green Linux CI**) are consolidated in the MODERNIZATION.md Phase 3 Status
> note. This document remains the executed plan of record.

## Context

This executes **Phase 3** of `MODERNIZATION.md`: replace CocoaAsyncSocket (`GCDAsyncUdpSocket`) with SwiftNIO beneath a stable internal socket abstraction, and make **Linux a first-class CI target**. The phase is **behavior-preserving** except for three deliberate, documented deltas (see "Deliberate behavior deltas" below): the public delegate API is unchanged, the Phase 1/2 characterization net stays green, and the actor/async redesign remains Phase 4.

Locked decisions (maintainer):

- Full migration; CocoaAsyncSocket removed this phase.
- **Timers are out of scope**: the vendored `Vendor/CwlDispatch.swift` GCD timers stay (libdispatch works on Linux) and are removed in Phase 4 with the async redesign. MODERNIZATION.md's Phase 3 text is amended accordingly (workstream I). Rationale: Phase 2 just hardened the timer machinery (generation tokens, queue hops); moving ticks onto event loops while state still lives on GCD queues would re-open exactly that area for no Phase 3 benefit.
- **Wire-format codec stays `Data` (amended 2026-07-15)**: PR 1 = NIO transport with boundary conversion (`ByteBuffer <-> Data` at the socket edge). PR 2 = kill the per-frame transmit allocation by pre-composing one `Data` packet per universe (existing offset-based replacers, no type change) under the Phase 1 round-trip net and the new benchmark guard (workstream J). **NIO `ByteBuffer` does not enter `Layers/*`, `Data+Extensions`, or the internal delegate payload** - it is confined to the transport layer; see the MODERNIZATION.md 2026-07-15 amendment and workstream H below. The PR 1 socket-edge conversion stays: at worst-case load (~45k packets/s = ~29 MB/s, ~0.1% of memory bandwidth) it is negligible, and a zero-copy `ByteBuffer` pipeline is not justified by measured need (it would cost the layering boundary and the centralized absolute-`Offset` parse model). Each PR independently green and revertible.
- Swift 6.2 toolchain, tools-version 6.2, `StrictConcurrency=targeted`, language mode `.v5` unchanged.

## Verified findings driving this phase

- `Shared/ComponentSocket.swift` is the **only** CocoaAsyncSocket consumer; `Source/sACNSource.swift:26` has a stray unused `import CocoaAsyncSocket` (delete early). There are **15** `ComponentSocket(type:...)` construction sites across the three socket owners.
- **GCDAsyncUdpSocket "dual-stack" is already two sockets.** The dependency checkout (`GCDAsyncUdpSocket.m`) maintains `socket4FD` + `socket6FD` sharing **one** socketQueue (so delegate delivery is totally ordered across families); `enableReusePort` sets `SO_REUSEPORT` on **both**; `SO_REUSEADDR` is set **unconditionally on every socket**; `IPV6_MULTICAST_IF` is set only via `sendIPv6MulticastOnInterface` (which sACNKit calls for transmit+IPv6); `IP_MULTICAST_IF` is **never called by sACNKit** - IPv4 multicast egress today relies solely on the transmit socket's bind-to-interface-address.
- **sACNKit never disables a family**: no `setIPv4Enabled`/`setIPv6Enabled` calls exist, so **every receive socket binds both `0.0.0.0:5568` and `[::]:5568` today regardless of `ipMode`**, and an `.ipv4Only` receiver currently accepts unicast IPv6 sACN (unicast needs no join). See delta B-1.
- **The socket lifecycle is reused, not one-shot**: owners create sockets once in `init` and keep the dictionary across `stop()` (`sACNReceiverRaw._stop()` calls `stopListening()` but retains the instances); `start()` re-runs `listenForSocket` on the **same** objects. GCD supports this (close resets flags; the socket is rebindable). The NIO facade must support re-listen.
- **GCD closes the whole socket on fatal errors**: 14 `closeWithError:` sites in `GCDAsyncUdpSocket.m` fire from fatal send/recv errno, producing `udpSocketDidClose(_:withError:)`; all three owners forward non-nil errors to client delegates. GCD's `close` tears down synchronously (dispatch_sync onto the socket queue).
- **Bogus-interface errors surface at join, not bind, for receivers**: receive-type `startListening` never passes the interface to `bind` (`ComponentSocket.swift:176` binds wildcard); the interface is first used by `joinMulticastGroup` - so a bad interface on a receiver throws `couldNotJoin`, not `couldNotBind`. (`ReceiverGroupTests` asserts only that *an* error is thrown, but the public error case is client-visible API behavior.)
- **GCD accepts the alias strings `"localhost"` and `"loopback"`** for both interface parameters and send hosts (`GCDAsyncUdpSocket.m:1191,1456-1479`), mapping them to the loopback addresses. `interface` is public API on every component.
- **All five layer structs are internal** (zero `public` under `Sources/sACNKit/Layers/`), as are the `Data` accessors/replacers in `Shared/Data+Extensions.swift`. The PR 2 pre-composed-buffer change is internal and non-breaking - the breaking-change gate does not apply.
- **Hostname string continuity is load-bearing**: `sACNReceiverRaw.processDataPacket` rejects packets whose `hostname`/`ipFamily` differ from the tracked source's. Post-migration this is self-consistent (NIO-vs-NIO string equality), but the *format* of `sourceHostname` reaching client delegates changes for scoped link-local IPv6 (delta B-2).
- **Owners rely on close-on-dealloc**: comments like "deinit first stops listening" drop `ComponentSocket` references without calling `stopListening()`; GCD closes on dealloc. The NIO impl needs an equivalent `deinit`, which in turn requires the facade's delegate reference to be weak (see D4).
- The roadmap's remaining cross-platform prep is **already discharged**: `Shared/Universe/Source.swift` has a portable host-name fallback and no Foundation networking types are used outside Darwin guards - the Phase 3 completion note can close that MODERNIZATION.md bullet without code changes.
- Prior spike (UDP_NIO reproducer, July 2026): `DatagramBootstrap` + `ChannelOptions.socketOption(.so_reuseaddr)`; Darwin `NIOBSDSocket.Option` has no named `.so_reuseport`, so `NIOBSDSocket.Option(rawValue: SO_REUSEPORT)` is used; `(channel as! MulticastChannel).joinGroup(_, device:)`; `SO_REUSEPORT` on every socket is necessary and sufficient for duplicate wildcard binds of UDP 5568 on Darwin.

## Deliberate behavior deltas (for maintainer sign-off)

Everything else in the phase is parity; these three are intentional changes, each recorded here rather than discovered later:

- **B-1 - `ipMode` becomes the enforced family contract.** Receive facades create channels only for the enabled families, so an `.ipv4Only` receiver no longer accepts unicast IPv6 sACN. Today's cross-family acceptance is accidental (a side effect of never disabling a family) and contradicts the public `ipMode` API. Alternative (strict parity: always bind both families) rejected as perpetuating the accident. Documented in README/changelog.
- **B-2 - scoped link-local IPv6 hostname format.** GCD uses `getnameinfo(NI_NUMERICHOST)` (`fe80::1%en0`); NIO's `SocketAddress.ipAddress` uses `inet_ntop` (no `%scope`). Client-visible `sourceHostname` strings change for link-local v6 senders. Documented, not code-mitigated.
- **B-3 - clean closes no longer produce a delegate callback.** All three owners guard `error != nil` and ignore clean closes today; the NIO facade delivers `socketDidCloseWithError` only for error-triggered teardown. Internal-only (the delegate protocol is internal), simplifies the close latch.
Two public error cases become unreachable but are preserved verbatim as API: `couldNotReceive` (NIO auto-reads; no separate begin-receive step) and `couldNotEnablePortReuse` (reuse-port is applied at bind, so a setsockopt failure surfaces as `couldNotBind`).

## Process & branching

- Branch **`modernization-phase3`** from `modernization-plan`.
- **Commit this plan as `docs/modernization/phase-3.md` before any code** (Phase 1/2 precedent).
- **Two PRs**, each independently green and revertible:
  - **PR 1 - NIO transport swap**: protocol seam, `NIOComponentSocket`, interface resolver, CocoaAsyncSocket removal, Linux CI, docs.
  - **PR 2 - transmit allocation win (amended)**: pre-compose one `Data` packet per universe, mutate in place, remove the per-frame concatenation; add the performance-benchmark guard. Codec stays `Data`; NIO stays in transport.
- One focused commit per step, each gated on green CI.

## Guardrails / non-goals

- No public API change; all six `sACNComponentSocketError` cases preserved verbatim (two become unreachable - see the deltas section).
- No timer changes; `Vendor/CwlDispatch.swift` and `MonotonicTimer` untouched (Linux-validated only).
- No actor/async; `.v5` + `StrictConcurrency=targeted` stay. Warning-clean under warnings-as-errors remains the bar.
- No new features (packet-info, vectored reads, TTL/buffer options) - listed as follow-ups only.
- Threading contract unchanged: all datagram/close/debug delivery lands on the owner's `socketDelegateQueue` via `.async` hops, per-channel FIFO with the delegate read **inside** the hop (the delegate is confined to `socketDelegateQueue`). Cross-family ordering is preserved by running both of a facade's channels on a **single shared event loop** (see D3) - matching the total order GCD gets from its shared socketQueue. The `.claude/rules/threading.md` one-way hierarchy is extended, not altered.
- Android/Windows compile-only CI: explicitly deferred (stretch tier; both need non-trivial toolchain scaffolding for no runtime guarantee - noted as follow-ups in MODERNIZATION.md).

## Workstreams

### A. Manifest & dependency - `Package.swift`

- Remove `CocoaAsyncSocket`; add `.package(url: "https://github.com/apple/swift-nio.git", from: "2.81.0")` with target products `NIOCore`, `NIOPosix`, `NIOFoundationCompat` (retained socket-edge `Data(buffer:)`/`ByteBuffer(data:)` conversion - the codec stays `Data`, so this bridge is permanent, not a PR 1-only stopgap). Floor 2.81.0 is the spike-verified minimum; bump to the current release at implementation time if resolution picks one anyway.
- **Warnings-as-errors scoping**: CI's `-Xswiftc -warnings-as-errors` applies to every module including dependencies - swift-nio would have to be warning-free under our exact toolchain. Move enforcement into the manifest with the per-target SwiftPM 6.2 setting `.treatAllWarnings(as: .error)` (SE-0443) on both targets, and drop the CI flag (keep `--build-tests`). Verify availability under tools 6.2 at implementation; fallback: keep the CI flag and pin an exact warning-clean swift-nio version.

### B. Interface resolver - new `Sources/sACNKit/Shared/NetworkInterfaceResolver.swift`

GCD resolved interface strings (name `"en0"`/`"lo0"`, IP string, or the aliases `"localhost"`/`"loopback"`) internally; NIO needs explicit plumbing (`System.enumerateDevices()`).

```swift
enum NetworkInterfaceResolver {

    /// Device matching a name-or-IP string for a family.
    static func device(matching interface: String, family: ComponentSocketIPFamily) throws(ResolverError) -> NIONetworkDevice

    /// The address to bind: the interface's address for the family (transmit),
    /// or the wildcard (0.0.0.0 / ::) for nil/"", at the given port.
    static func bindAddress(interface: String?, family: ComponentSocketIPFamily, port: UInt16) throws(ResolverError) -> SocketAddress

}
```

- Match rule: device where `name == interface || address?.ipAddress == interface`, filtered to the requested family, preferring entries that carry an address for that family (a device appears once per address). The aliases `"localhost"` and `"loopback"` resolve to the loopback device (GCD parity; `interface` is public API, so dropping them would be a client-visible regression).
- `nil`/`""` = all-interfaces preserved: wildcard bind; multicast join passes `device: nil` (kernel default - matches GCD's `interface: nil` join).
- **Resolution timing preserves today's public error cases**: transmit sockets resolve at `startListening` (GCD passes the interface to transmit bind) -> failure is `couldNotBind(message:)`; receive sockets bind wildcard **without** resolving (GCD never passes the interface to receive bind) and resolve **lazily at `join`/`leave`** -> failure is `couldNotJoin`/`couldNotLeave(multicastGroup:)`, exactly where a bogus interface fails today. Setting v6 egress -> `couldNotAssignMulticastInterface(message:)`. Internal `ResolverError` is mapped at the `NIOComponentSocket` call sites, never thrown outward.
- Unit-testable without sockets via an overload taking a device list. If `NIONetworkDevice` is not test-constructible, add a thin internal descriptor struct (name/address/index) that production code builds from `NIONetworkDevice` and tests build directly.

### C. Protocol seam - `Shared/ComponentSocket.swift`

- **`ComponentSocket` becomes the protocol (keeps its name)**; the existing GCD class is renamed **`GCDComponentSocket`** and conforms, so the flip commit is a behavioral no-op that compiles on its own (see sequencing - the NIO class cannot be introduced before the protocol exists, since `NIOComponentSocket: ComponentSocket` would otherwise subclass the NSObject class and collide on stored properties). The file keeps `ComponentSocketType`, `ComponentSocketIPFamily`, `ComponentSocketDelegate`, and `sACNComponentSocketError` unchanged:

```swift
protocol ComponentSocket: AnyObject {

    var id: UUID { get }
    var interface: String? { get }
    var delegate: ComponentSocketDelegate? { get set }

    func enableReusePort() throws
    func join(multicastGroup: String) throws
    func leave(multicastGroup: String) throws
    func startListening(onInterface interface: String?) throws
    func stopListening()
    func send(message data: Data, host: String, port: UInt16)

}
```

- A protocol requirement cannot be declared `weak`; **conforming implementations must store the delegate weakly** (today's `weak var delegate` breaks the retain cycle formed by owners holding sockets strongly while setting `socket.delegate = self`; a strong reference would leak every component and make close-on-dealloc unreachable). Stated as a doc comment on the requirement and asserted by a deallocation test (workstream F).
- `ComponentSocketDelegate` signatures untouched (`for socket: ComponentSocket` now means the protocol - source-compatible for all three conformers). `NSObject`/`GCDAsyncUdpSocketDelegate` disappear with the GCD class.
- Owner churn is near-zero by construction: `[String: ComponentSocket]` dictionaries, `socket.id`, `socket.interface`, `socket.delegate`, and every call site compile unchanged. The only owner edits are the **15** construction sites in `sACNSource`, `sACNReceiverRaw`, `sACNDiscoveryReceiver` (renamed class at the protocol flip, then `NIOComponentSocket` at the swap), plus deleting the stray import.
- **No factory/injection seam this phase** (deliberate YAGNI): no Phase 3 test needs a socket mock (receiver suites drive the `process(data:...)` seam; NIO-impl tests bind real sockets); protocol-typed storage makes later injection a construction-site-only change; Phase 4 rebuilds this layer anyway.

### D. `NIOComponentSocket` - new `Sources/sACNKit/Shared/NIOComponentSocket.swift`

`final class NIOComponentSocket: ComponentSocket`, same `init(type:ipMode:port:delegateQueue:)` signature (delegateQueue = the owner's `socketDelegateQueue`; the per-socket GCD `socketQueue` disappears - one event loop per facade replaces it).

**D1. Channel-per-family mapping (two channels behind one facade).** Rationale: (a) structurally what GCD does today (two FDs), so per-datagram family reporting and hostname formats are preserved - a single `::` bind with `IPV6_V6ONLY=false` would report IPv4 senders as v4-mapped `::ffff:a.b.c.d`, breaking the hostname/ipFamily continuity check; (b) IPv4 group joins are not expressible through a v6 channel's `joinGroup`; (c) `bindv6only` defaults differ across Linux configs. Families follow `ipMode` (delta B-1: today GCD binds both families regardless; the facade honors the mode).

| type x ipMode | channels | bind |
|---|---|---|
| transmit, ipv4Only | 1x v4 | interface v4 addr (or `0.0.0.0`), port 0 |
| transmit, ipv6Only | 1x v6 | interface v6 addr, port 0; + `IPV6_MULTICAST_IF` = device index |
| transmit, ipv4And6 | v4 + v6 | each family's interface addr; `IPV6_MULTICAST_IF` on the v6 channel |
| receive, ipv4Only | 1x v4 | `0.0.0.0:5568` (deliberately all addresses; joins filter) |
| receive, ipv6Only | 1x v6 | `[::]:5568`; joins pass lazily-resolved device |
| receive, ipv4And6 | v4 + v6 | both wildcard binds; join/leave routed by group family |

Routing: `join`/`leave`/`send` pick the channel by address family (`host.contains(":")` - all destinations today are literal IPs from `NetworkDefinitions`, so `SocketAddress(ipAddress:port:)` needs no DNS; the `"localhost"`/`"loopback"` send-host aliases route via the resolver). The existing `precondition(!ipMode.usesIPv6() || interface != nil)` is retained.

**D2. Socket-option mapping (parity with the verified GCD syscalls):**

| GCD today | NIO mapping | when |
|---|---|---|
| `SO_REUSEADDR = 1` unconditionally | `ChannelOptions.socketOption(.so_reuseaddr), value: 1` | every channel (keep parity) |
| `SO_REUSEPORT = 1` via `enableReusePort` (both receivers call it unconditionally; the source never does) | same option via `NIOBSDSocket.Option(rawValue: SO_REUSEPORT)` (spike-verified), applied **unconditionally on receive channels keyed off `socketType`**; `enableReusePort()` becomes a protocol-shape no-op (no mutable flag, no call-order fragility); `couldNotEnablePortReuse` acknowledged unreachable (a setsockopt failure surfaces as `couldNotBind`) | receive channels |
| transmit bind to interface addr, port 0 | `bootstrap.bind(to: resolver.bindAddress(...))` | per channel |
| receive bind all addresses, port 5568 | wildcard bind per family; interface **not** resolved at bind (parity - see workstream B resolution timing) | per channel |
| `joinMulticastGroup(_:onInterface:)` | `(channel as! MulticastChannel).joinGroup(SocketAddress, device:)`, device resolved lazily here | receive only (transmit no-op, as today) |
| `leaveMulticastGroup` | `.leaveGroup(_:device:)` | receive only |
| `sendIPv6Multicast(onInterface:)` (`IPV6_MULTICAST_IF`) | `channel.setOption(.socketOption(.ipv6_multicast_if), value: deviceIndex)` (named-case spelling unverified; raw-value fallback) | v6 transmit channel |
| `IP_MULTICAST_IF`: never set by sACNKit | do not set initially; risk R5 defines the test-evidence decision rule for Linux | - |
| `IP_MULTICAST_LOOP`: kernel default ON | untouched; loopback tests are the guard | - |
| max receive size | `.recvAllocator: FixedSizeRecvByteBufferAllocator(capacity: 2048)` (max sACN packet 638 B) | every channel |
| `beginReceiving()` | automatic (`autoRead`); `couldNotReceive` kept (public API) but unreachable | - |

**D3. Event loop & lifecycle.** The facade takes **one event loop** at init (`MultiThreadedEventLoopGroup.singleton.next()`) and binds **both** channels on it. The shared singleton group is never shut down by the library (NIO's documented library pattern - no per-component shutdown hazards); the single shared loop preserves the cross-family delivery order GCD gets from its shared socketQueue and simplifies handler state.

- **Re-listen support (required)**: owners create sockets once and reuse them across `stop()`/`start()` (verified). NIO channels are one-shot, so `startListening` **creates fresh channels on every call**; each listen cycle resets the close latch and stored first-error. A facade is therefore reusable indefinitely, like the GCD socket.
- **Synchronous close (parity)**: `stopListening()` runs `close().wait()` per channel (permitted - called from GCD queues only, see D4 wait rule). This is parity, not a delta: GCD's `close` already tears down via `dispatch_sync` before returning (`GCDAsyncUdpSocket.m:4811-4824`), so today's `stopListening()` returns with the FDs closed. A fire-and-forget close would *introduce* a window where an old, still-joined channel delivers duplicate packets into the next session on quick `stop()`/`start()` or `updateInterfaces` churn - `close().wait()` avoids opening it.
- **`deinit`**: `close(promise: nil)` fire-and-forget on any open channels (cannot safely block in deinit), preserving owners' close-on-dealloc reliance. Reachable because the delegate is weak (workstream C).

**Synchronous bind:** `startListening` runs `bootstrap.bind(...).wait()` on the caller's `socketDelegateQueue`. No-deadlock argument extending the one-way hierarchy: event loops sit strictly below all component queues - an event loop only ever `.async`-hops up to `socketDelegateQueue` and never blocks on or syncs to any GCD queue, so a GCD queue blocking down on an event-loop future cannot form a cycle. New threading.md rule: `.wait()` on NIO futures is permitted only from GCD queues, never from an event loop or channel handler.

**D4. Threading, delivery & error contract.** One `ChannelInboundHandler` (`DatagramHandler`) per channel. `channelRead` (on the event loop): unwrap `AddressedEnvelope<ByteBuffer>`, extract `remoteAddress.ipAddress`/`port` and the channel's family, copy payload (`Data(buffer:)` - the PR 1 boundary copy), then a single `socketDelegateQueue.async` hop that reads `self.delegate` (weak) **inside the hop** (the delegate is confined to `socketDelegateQueue`, exactly where GCD delivered callbacks) and emits `debugLog` + `receivedMessage`. Per-channel FIFO preserved; cross-family order preserved by the shared event loop (D3).

- **Error-triggered close (parity with GCD's whole-socket teardown)**: on `errorCaught` with a fatal error (fatal = any send/recv errno except the transient would-block/interrupted family, `EWOULDBLOCK`/`EAGAIN`/`EINTR` - GCD's effective classification), the facade **closes both channels immediately** and delivers `socket(self, socketDidCloseWithError: error)` once per listen cycle on `socketDelegateQueue`. GCD does exactly this from fatal send/recv errno (14 `closeWithError:` sites); without it, a mid-session interface loss would be stored silently and a receiver would look alive while delivering nothing. Clean closes (from `stopListening`/`deinit`) deliver no callback (delta B-3 - owners ignore nil-error closes today).
- **Send mapping:** `send` attaches write-completion callbacks producing the same debugLog strings as today (`did send data` / `did not send data due to error ...`) - parity with today's per-send delegate callback cost, plus one promise allocation per write. Gating on `delegate != nil` would skip nothing: the socket-level delegate is the *owner*, always non-nil while listening; the idle cost sits downstream, where the owner's `debugLog` forwards to a usually-nil client `debugDelegate`. The real optimization - a `debugLoggingEnabled` flag on the socket, set by owners from their `debugDelegate` setters (both confined to `socketDelegateQueue`, so safe) - is deferred as a follow-up to keep owner churn near-zero, since the per-send cost matches today's. Fire-and-forget semantics preserved (no throw).
- **Sendability under `StrictConcurrency=targeted` + warnings-as-errors:** keep mutable facade state (channels, interface, close latch, stored error) in `NIOLockedValueBox`; keep handler captures `Sendable`. If the weak-delegate/self captures prove irreducible, the documented fallback is a single, invariant-documented `@unchecked Sendable` on `NIOComponentSocket` only (transport class, real confinement, TSan-guarded), recorded in this doc if used.

### E. Owner integration

- Delete stray `import CocoaAsyncSocket` from `sACNSource.swift:26` (first code commit).
- The 15 construction sites change twice: to `GCDComponentSocket(...)` at the protocol flip, then to `NIOComponentSocket(...)` at the swap. Nothing else changes in `sACNSource`, `sACNReceiverRaw`, `sACNDiscoveryReceiver`; `sACNReceiver`/`sACNReceiverGroup` untouched.
- Existing `listenForSocket` flows (`delegate = self; [enableReusePort]; startListening; join...`) remain valid; `enableReusePort()` is now a no-op and reuse is keyed off `socketType`.

### F. Tests

- New `Tests/sACNKitTests/TestInterface.swift`: `static var loopback: String` = `"lo"` on Linux, `"lo0"` elsewhere; replace the `"lo0"` literals in `ReceiverGroupTests`.
- New `NetworkInterfaceResolverTests.swift` (ungated, no sockets): resolve loopback by name, by IP (`127.0.0.1`, `::1`), and by the `"localhost"`/`"loopback"` aliases; family filtering; unknown name/IP throws; wildcard for nil/"".
- New `NIOComponentSocketTests.swift` (gated `SACNKIT_NETWORK_TESTS=1`): transmit bind port 0 per ipMode; receive bind 5568; two receive sockets bind 5568 concurrently (reuse-port, the shared-bind story); join + leave v4 group on loopback; **bogus interface throws `couldNotJoin` from `join` on receive sockets and `couldNotBind` from `startListening` on transmit sockets** (today's public error-case behavior, preserved by the lazy-resolution design); **stop/start re-listen cycle** (bind, join, receive, stopListening, startListening again, receive again on the same facade); **deallocation** (component released -> facade and channels torn down; guards the weak-delegate requirement); datagram delivery arrives on the delegate queue with correct hostname/port/family.
- Shared helpers (LockedBox, timeout constants) are **hoisted into common test support** rather than copied a fourth time (ties into the Phase 2 test-support consolidation item).
- Existing gated `ReceiverGroupTests` network tests and `LoopbackTests` run unchanged - they are the acceptance gate for the swap.
- Linux promotion investigation: run the gated network suites on the Linux runner non-blocking first; promote to required only after a stability window (Phase 2 precedent).

### G. CI - `.github/workflows/ci.yml`

Keep all four macOS jobs (drop `-Xswiftc -warnings-as-errors` if workstream A's manifest setting lands). **Extend the macOS loopback job's filter to `"LoopbackTests|ReceiverGroupTests|NIOComponentSocketTests"` and update its comment** - otherwise the gated NIO socket behaviors (dual bind, join/leave, typed errors) would run in no macOS CI job at all. Add:

```yaml
  linux:
    name: Build & Test (Linux)
    runs-on: ubuntu-latest
    container: swift:6.2-noble
    steps:
      - uses: actions/checkout@v7
      - name: Swift version
        run: swift --version
      - name: Build
        run: swift build --build-tests
      - name: Test
        run: swift test

  linux-loopback:
    name: Loopback (Linux, non-blocking)
    runs-on: ubuntu-latest
    container: swift:6.2-noble
    steps:
      - uses: actions/checkout@v7
      - id: loopback
        continue-on-error: true
        run: swift test --filter "LoopbackTests|ReceiverGroupTests|NIOComponentSocketTests"
        env:
          SACNKIT_NETWORK_TESTS: "1"
      - if: steps.loopback.outcome == 'failure'
        run: echo "::warning title=Linux loopback failed (non-blocking)::..."
```

- **R5 evidence loop**: `NIOComponentSocketTests` includes a **unicast-loopback control test** (send to `127.0.0.1`, assert delivery - no multicast involved). Decision rule, pre-committed: if the control passes on the Linux runner but v4 multicast egress/delivery fails, the failure implicates egress routing, and `IP_MULTICAST_IF` is set on v4 transmit channels as a documented deviation from strict parity; if the control also fails, the container's networking is unviable for loopback tests and R5 stays open (recorded in the completion note, to be settled on real Linux hardware).
- Notes: `--enable-test-discovery` is obsolete; Linux TSan deferred (macOS TSan job covers shared code; add later if cheap). Replace the trailing "Linux ... added in Phase 3" comment. Android/Windows compile-only jobs deferred.

### H. PR 2 - Transmit allocation win (amended 2026-07-15; staged second, independently revertible)

> **Amendment.** PR 2 originally migrated `Layers/*` parse/build, the in-place replacers, and the internal `ComponentSocketDelegate` payload to NIO `ByteBuffer`. That coupling is dropped: `ByteBuffer` stays confined to the transport layer (`NIOComponentSocket` / `NetworkInterfaceResolver`), the codec stays `Data`, and the socket-edge boundary conversion from PR 1 is kept. See the MODERNIZATION.md 2026-07-15 amendment for the rationale (layering, negligible boundary-copy cost, avoiding the reader-index parse model). PR 2 now delivers only the measurable performance win, on `Data`.

All affected types are internal (verified), so this is non-breaking by construction. Guarded by the Phase 1 layer round-trip/malformed suites, the TX emission suite, and the new benchmark harness (workstream J).

- **Receive path:** unchanged. Layer `parse(fromData:)` stays `Data`-based on the Phase 1 stdlib non-allocating `loadUnaligned`; the socket delivers `Data` as today. No `process(buffer:)` seam, no delegate-payload flip - so the Phase 2 `process(data:...)` receiver seam is untouched here (its Phase 4 removal is unaffected).
- **Transmit path (the win):** today `buildDataMessages` re-concatenates `rootLayer + framingLayer + dmpLayer` per universe per frame (one ~638 B `Data` allocation each, at up to 44 fps x N universes x families). PR 2 pre-composes **one full `Data` packet per universe** (root+framing+DMP joined once at build/update time), stored on `SourceUniverse`, and the per-frame path mutates it in place at absolute offsets with the existing replacers (`replacingSequence`/`replacingOptions`/`replacingPriority`/`replacingDMPLayerValues`), removing the per-frame join. This makes `.claude/rules/protocol.md`'s "mutated in place, never rebuilt at frame rate" literally true. The replacers stay on `Data`; `ComponentSocket.send(message:)` stays `Data` (the transport converts to `ByteBuffer` at the edge).
- **Levels vs priority:** a universe emits either a NULL-start-code (levels) or a `0xDD` (PAP) packet, so fold the two DMP layers `SourceUniverse` already models (`dmpLevelsLayer` / `dmpPrioritiesLayer`) into **two** pre-composed full packets (a levels packet and a priorities packet), each mutated in place; sequence/options are written into whichever is being sent, matching today's logic. Offset bookkeeping: the framing/DMP `Offset` enums become offsets into the composed packet (add the root-layer length), centralized once so the replacers keep single-source-of-truth offsets.
- No fixture or assertion churn: the round-trip and TX-emission suites are `Data`-based already and assert byte-identical output.
- Cleanup: the `Data` accessors/replacers stay (they are the mechanism); drop only the now-unused per-frame concatenation in `buildDataMessages`.

### I. Docs & rules updates

- **MODERNIZATION.md:** Phase 3 bullet (retire CwlDispatch) - timers deferred to Phase 4 (libdispatch is portable; the async redesign deletes them wholesale, avoiding churning timer plumbing twice); ByteBuffer bullet - amended (2026-07-15): codec stays `Data`, NIO confined to transport, PR 2 delivers the transmit allocation win via a pre-composed per-universe `Data` buffer; Verification strategy gains the "Performance benchmarks" item; deliverable - CocoaAsyncSocket removed, CwlDispatch remains until Phase 4, Android/Windows deferred; key files - drop "CwlDispatch (removed)"; Phase 4 section gains CwlDispatch removal and the `process(data:)` shim removal (timing bullet + key files). The cross-platform prep bullet (host name / FoundationNetworking) is recorded as already discharged. On completion: "Status: complete" pointer with honest-history deviations (phase-2.md precedent), including the B-1..B-3 deltas and any R5/R6 outcomes.
- **AGENTS.md:** dependency line (CocoaAsyncSocket -> swift-nio), Layout (`Shared/` gains the two new files; CwlDispatch note -> "removed in Phase 4"), Networking line -> SwiftNIO done, platforms -> Linux supported.
- **`.claude/rules/threading.md`:** add the event-loop tier - event loops sit below all component queues; event loop -> `socketDelegateQueue` is `.async`-only with the delegate read inside the hop; `.wait()` only from GCD queues, never from an event loop/handler; one shared event loop per facade preserves cross-family ordering.
- **`.claude/rules/timing.md`:** CwlDispatch line -> "removed in Phase 4".
- **`.claude/rules/protocol.md`** (PR 2): pre-composed per-universe packet buffer mutated in place (replacers stay on `Data`; the "never rebuilt at frame rate" rule made literally true). Note NIO `ByteBuffer` is transport-only and does not appear in the wire format.
- **README.md:** Requirements add Linux (Swift 6.2); document deltas B-1 and B-2.

### J. Performance benchmark harness (regression guard, added 2026-07-15)

Purpose: catch **performance** regressions independently of the correctness net - specifically a reintroduced per-frame allocation. Not a correctness gate; correctness stays with the Phase 1 characterization suites.

- New benchmark cases in `Tests/sACNKitTests/` (behind an env flag, e.g. `SACNKIT_BENCH=1`, so ordinary `swift test` stays fast) measuring: (a) single data-packet `parse` (`RootLayer` -> `DataFramingLayer` -> `DMPLayer`); (b) `buildDataMessages` at **1 / 64 / 256** universes, dual-stack; (c) the in-place replacers.
- **Allocation count is the primary, deterministic signal** (wall-clock on shared CI runners is noisy). Assert that the per-frame transmit path allocates a **bounded, universe-count-independent** number of buffers after the pre-composed-buffer change - that is exactly the regression this guards. Where a portable allocation probe is unavailable on Linux, gate the assertion to Darwin (`malloc` zone counters) and keep the throughput measurement cross-platform.
- **Baseline captured in the same PR as the transmit change** (sequencing step 9) so the win is measured, not assumed, and later diffs are compared against it.
- CI: a **non-blocking** job (`continue-on-error`) records the numbers as a trend; the deterministic allocation-count assertions run in the normal test job (they are cheap and stable) and are the hard gate.

## Sequencing (one commit each, green-CI gate)

**PR 1 - `modernization-phase3`:**

1. Plan doc (`docs/modernization/phase-3.md`).
2. A: add swift-nio (+ warnings-as-errors swap), delete stray import; CocoaAsyncSocket stays temporarily. *Guard: full suite.*
3. B + F: `NetworkInterfaceResolver` + unit tests + `TestInterface.loopback` helper + hoisted test support. *Guard: new resolver tests + gated group tests locally.*
4. C: **protocol flip** - `ComponentSocket` becomes the protocol, GCD class renamed `GCDComponentSocket` and conforms, 15 construction sites updated. Behavioral no-op. *Guard: full suite + gated network suites locally.*
5. D + G(macOS): `NIOComponentSocket` added alongside (unused by owners) + gated `NIOComponentSocketTests` + macOS loopback job filter extended. *Guard: gated NIO tests locally + macOS loopback job.*
6. E: **the swap** - construction sites -> `NIOComponentSocket`, `GCDComponentSocket` + CocoaAsyncSocket dependency deleted. *Guard: full suite, TSan, gated network suites + LoopbackTests locally.*
7. G(Linux): Linux CI jobs incl. the R5 evidence loop, added **non-blocking**. *Guard: the new jobs themselves. Note: Linux does not yet build (concurrency captures under warnings-as-errors, CwlDispatch Darwin symbols, a CInt/Int socket-option mismatch); the job is non-blocking, not a merge gate - see the completion note.*
8. I: docs/rules amendments.

**PR 2 (after PR 1 merges) - amended 2026-07-15:**

9. Benchmark harness + baseline (workstream J), captured **before** the transmit change so the win is measured. *Guard: non-blocking benchmark job + deterministic allocation assertions.*
10. Transmit pre-composed per-universe `Data` buffer + in-place replacers; remove the per-frame concatenation in `buildDataMessages` (codec stays `Data` - no `ByteBuffer`, no delegate-payload flip, receive path untouched). *Guard: TX emission suite (byte-identical), loopback, benchmark allocation assertion.*
11. protocol.md update (pre-composed per-universe buffer) + drop the now-unused concatenation helper.

## Verification

- `swift build --build-tests` + `swift test` green on macOS (Xcode 26) **and** Linux (swift:6.2-noble); warnings-as-errors enforced via the manifest setting, or via the CI flag + pinned NIO if the SE-0443 fallback is taken (workstream A).
- Gated network suites green locally on macOS (required, pre-swap and post-swap): dual 5568 reuse-port bind, v4+v6 join/leave, bogus-interface typed errors (`couldNotJoin` receive / `couldNotBind` transmit), stop/start re-listen, deallocation, unicast control, loopback end-to-end merge.
- Linux gated suites run in the **non-blocking** job; green there is the promotion criterion, not a phase gate (the job's outcome feeds the R5 decision rule either way).
- TSan job green (covers the new event-loop <-> queue hops).
- Public API surface diff: no signature deltas.
- PR 2: byte-identical packet output where asserted (round-trip and TX emission suites unchanged in expectations); the transmit per-frame allocation count is bounded and universe-count-independent (benchmark allocation assertion, workstream J); NIO `ByteBuffer` appears in no file under `Layers/`, `Data+Extensions.swift`, or the `ComponentSocketDelegate` payload (grep-verifiable layering check).
- `swift format lint --strict` clean.

**Verification boundary (untested at runtime):** the gated socket tests are IPv4-only, so the IPv6 paths have **no runtime coverage** and are compile-/API-verified only - specifically the `IPV6_V6ONLY` family separation (the v4-mapped `::ffff:` continuity hazard), the `IPV6_MULTICAST_IF` egress (correct `IPPROTO_IPV6` option level), and the `withPort` scope-id preservation for link-local binds. An IPv6 multicast delivery test was deliberately declined to avoid flakiness on runners without reliable v6 loopback; add one once a known-good v6 runner is available before treating these as tested.

## Risks / notes

- **R1 - kqueue vs epoll multicast deltas:** Linux load-balances unicast across reuseport sockets but delivers multicast to all joined members (the property we need); Darwin needs REUSEPORT on every socket for duplicate 5568 binds (spike-verified). Guard: gated dual-bind + join tests on both OSes.
- **R2 - hostname format delta:** see B-2.
- **R3 - dual-stack edge:** in `.ipv4And6` with an interface lacking an address for one family, match GCD's behavior (throw `couldNotBind` vs degrade to one family) - verify against GCD during implementation and pin with a test if reachable.
- **R4 - implicit GCD behaviors, now explicit in the design:** unconditional `SO_REUSEADDR` (D2); re-listen after stop (D3); synchronous close (D3); error-triggered close-and-notify (D4); close-on-dealloc via `deinit` + weak delegate (C/D3).
- **R5 - IPv4 multicast egress on Linux:** today's v4 egress-by-bind is a Darwin-routing side effect; on Linux egress may follow the route table instead. The unicast control test + pre-committed decision rule in workstream G disambiguates container-networking failure from egress misrouting; setting `IP_MULTICAST_IF` on v4 transmit channels is the documented deviation if egress is implicated. If the container cannot support the tests at all, R5 is recorded open in the completion note for settling on real Linux hardware.
- **R6 - Sendability of the NIO facade** under targeted checking + warnings-as-errors; fallback is a scoped, documented `@unchecked Sendable` on `NIOComponentSocket` only.
- **Unverified items** (flagged for implementation): named `.ipv6_multicast_if` option spelling (raw-value fallback spike-proven for `SO_REUSEPORT`); `NIONetworkDevice` test-constructibility (fallback descriptor struct); `.treatAllWarnings(as:)` under tools 6.2 (fallback: CI flag + pinned NIO); Linux-container multicast loopback viability (the non-blocking job + control test answer empirically).

## Key files

`Package.swift`, `Sources/sACNKit/Shared/ComponentSocket.swift` (protocol + delegate + error),
`Sources/sACNKit/Shared/NIOComponentSocket.swift` (new), `Sources/sACNKit/Shared/NetworkInterfaceResolver.swift` (new),
`Sources/sACNKit/Source/sACNSource.swift`, `Sources/sACNKit/Receiver/sACNReceiverRaw.swift`,
`Sources/sACNKit/Receiver/sACNDiscoveryReceiver.swift`,
`Sources/sACNKit/Source/sACNSource.swift` (PR 2, remove per-frame concat), `Sources/sACNKit/Source/SourceUniverse.swift` (PR 2, pre-composed buffers),
`Tests/sACNKitTests/{NetworkInterfaceResolverTests,NIOComponentSocketTests,TestInterface}.swift` (new),
`Tests/sACNKitTests/PerformanceBenchmarks.swift` (new, PR 2),
`Tests/sACNKitTests/{ReceiverGroupTests,PacketFixtures}.swift`, `.github/workflows/ci.yml`,
`MODERNIZATION.md`, `AGENTS.md`, `.claude/rules/{threading,timing,protocol}.md`, `README.md`.
