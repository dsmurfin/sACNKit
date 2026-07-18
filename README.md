# sACNKit

An implementation of ANSI E1.31-2018, the Entertainment Technology Lightweight streaming protocol for
transport of DMX512 using ACN (sACN), in Swift.

sACNKit provides a transmitting source, merged and raw receivers, a universe-discovery receiver, and a
standalone HTP / per-address-priority merge engine.

## Requirements

- Swift 6.2 toolchain (Xcode 26 or newer)
- iOS 18+ / macOS 15+ / tvOS 18+ / visionOS 2+ / Linux

> The library is undergoing a phased modernization (SwiftNIO transport, a Swift Concurrency API, and
> Linux support). See [MODERNIZATION.md](MODERNIZATION.md) for the roadmap.

## Installation

Add sACNKit to your `Package.swift`:

```swift
dependencies: [
    .package(url: "https://github.com/dsmurfin/sACNKit", from: "0.1.0")
]
```

Or, in Xcode: **File > Add Package Dependencies...** and enter the repository URL.

## Usage

### Transmitting

`sACNSource` is a Swift `actor`: its lifecycle and mutation API are `async`, and it reports lifecycle
events on an `AsyncStream` rather than a delegate.

```swift
import sACNKit

let source = sACNSource(name: "My Source")
try await source.addUniverse(sACNSourceUniverse(number: 1, levels: Array(repeating: 0, count: 512)))

// Subscribe before start() to observe the first (edge-triggered) transmissionStarted event.
Task {
    for await event in source.events { print(event) }
}

try await source.start()

// Update levels for universe 1.
try await source.updateLevels(Array(repeating: 255, count: 512), in: 1)

// stop() awaits the termination drain (3 packets), then returns to idle.
await source.stop()
```

### Receiving

Every receiver is a Swift `actor` (like `sACNSource`): the lifecycle API is `async`, and merged data
and lifecycle events arrive on `AsyncStream`s rather than delegate callbacks.

```swift
import sACNKit

let receiver = sACNReceiver(universe: 1)
Task { for await frame in receiver!.data { print(frame.levels) } }
Task { for await event in receiver!.events { print(event) } }
try await receiver?.start()
```

Use `sACNReceiverGroup` to receive and merge many universes behind one API (its `data`/`events` carry
the `universe`), or `sACNReceiverRaw` for un-merged per-source data. `sACNMerger` is a standalone HTP /
per-address-priority merge engine.

`sACNDiscoveryReceiver` reports sources seen via universe discovery; discovered sources arrive on its
`discovery` `AsyncStream`.

```swift
let discovery = sACNDiscoveryReceiver()
Task { for await source in discovery.discovery { print(source.cid, source.universes) } }
try await discovery.start()
```

Notes on stream delivery. Each `data`/`events`/`debugLog` property returns an independent subscription,
so multiple consumers can observe the same receiver. `data` buffers the newest frame (a slow consumer
gets the latest DMX, not a backlog); `events` is best-effort drop-oldest, so a consumer that stalls for
long enough can miss an event such as `.sourcesLost`. Consumers run off-actor, so you may freely call
back into a receiver (for example `information(for:)`) from within a `for await` loop without deadlock.
`stop()` is not a delivery barrier - elements already yielded may still be observed after it returns -
and `information(for:)` reflects current state, so it may throw for a source a just-delivered frame
listed as active.

### Transport notes (SwiftNIO)

The transport is SwiftNIO. Two behaviours differ from earlier CocoaAsyncSocket-based releases:

- A component's `sACNIPMode` is now enforced: an `ipv4Only` component only binds IPv4, so it no longer
  incidentally receives IPv6 unicast traffic (and vice versa). Use `ipv4And6` for dual-stack.
- Source hostnames for scoped link-local IPv6 senders are reported without the zone id
  (`fe80::1` rather than `fe80::1%en0`).

## Public types

- `sACNSource` - transmit sACN.
- `sACNReceiver` / `sACNReceiverGroup` - receive merged sACN.
- `sACNReceiverRaw` - receive raw, per-source sACN.
- `sACNDiscoveryReceiver` - receive universe discovery.
- `sACNMerger` - HTP / per-address-priority merge engine.

## Documentation

API documentation is provided via DocC (`Sources/sACNKit/Documentation.docc`). Build it in Xcode with
**Product > Build Documentation**, or with `swift package generate-documentation`.

## License

sACNKit is released under the MIT license. See [LICENSE](LICENSE).
