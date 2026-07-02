# sACNKit

An implementation of ANSI E1.31-2018, the Entertainment Technology Lightweight streaming protocol for
transport of DMX512 using ACN (sACN), in Swift.

sACNKit provides a transmitting source, merged and raw receivers, a universe-discovery receiver, and a
standalone HTP / per-address-priority merge engine.

## Requirements

- Swift 6.2 toolchain (Xcode 26 or newer)
- iOS 17+ / macOS 14+ / tvOS 17+ / visionOS 1+

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
