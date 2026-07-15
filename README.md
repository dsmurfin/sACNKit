# sACNKit

An implementation of ANSI E1.31-2018, the Entertainment Technology Lightweight streaming protocol for
transport of DMX512 using ACN (sACN), in Swift.

sACNKit provides a transmitting source, merged and raw receivers, a universe-discovery receiver, and a
standalone HTP / per-address-priority merge engine.

## Requirements

- Swift 6.2 toolchain (Xcode 26 or newer)
- iOS 17+ / macOS 14+ / tvOS 17+ / visionOS 1+ / Linux

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

```swift
import sACNKit

let source = sACNSource(name: "My Source", delegateQueue: .main)
try source.addUniverse(sACNSourceUniverse(number: 1, levels: Array(repeating: 0, count: 512)))
try source.start()

// Update levels for universe 1.
try source.updateLevels(Array(repeating: 255, count: 512), in: 1)
```

### Receiving

```swift
import sACNKit

let receiver = sACNReceiver(universe: 1, delegateQueue: .main)
receiver?.setDelegate(self) // conform to sACNReceiverDelegate
try receiver?.start()
```

Use `sACNReceiverGroup` to receive and merge many universes with a single delegate, or
`sACNReceiverRaw` for un-merged per-source data. `sACNDiscoveryReceiver` reports sources seen via
universe discovery, and `sACNMerger` is a standalone HTP / per-address-priority merge engine.

All delegate callbacks are delivered asynchronously on the `delegateQueue` you provide, in the
order packets were processed. A serial queue is recommended; internal state is safe even if the
queue is concurrent, and you may call back into a component (for example `information(for:)`)
from within a callback.

Because delivery is asynchronous, `stop()` and `setDelegate(nil)` are not delivery barriers:
callbacks already enqueued may still arrive after either call returns (`setDelegate(nil)` keeps the
previous delegate alive for those in-flight deliveries). Similarly, `information(for:)` reflects the
component's current state, so it may throw for a source listed in the callback payload you are
handling if that source was lost in the meantime. Tear down resources your delegate uses only after
queued callbacks have drained (for example after a barrier block on your delegate queue).

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
