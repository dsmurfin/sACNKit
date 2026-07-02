# Contributing to sACNKit

Thanks for your interest in contributing.

## Requirements

- Swift 6.2 toolchain (Xcode 26 or newer)
- iOS 17+ / macOS 14+ / tvOS 17+ / visionOS 1+

## Build, test and format

```sh
swift build
swift test
swift format lint --strict --recursive --configuration .swift-format Sources Tests
```

`swift-format` is the formatter of record; run it (or `swift format --in-place ...`) before committing.
CI runs the build, tests and the format check on every push and pull request.

## Tests

Tests use [swift-testing](https://developer.apple.com/documentation/testing) (`@Test` / `#expect`).
Pure components (wire-format layers, `sACNMerger`, `SourceUniverse`, and the transmit builder) are
exercised without sockets or timers. Please add or update tests alongside behavioral changes.

## Branching and commits

- Branch from `main` (feature work) or from the relevant modernization branch.
- Keep commits focused; write descriptive messages.
- Larger work follows the phased plan - see [MODERNIZATION.md](MODERNIZATION.md) and the per-phase
  plans under `docs/modernization/`.

## Modernization

sACNKit is being modernized in phases (SwiftNIO transport, a Swift Concurrency API, cross-platform
support, and upstream ETC correctness fixes). Before starting substantial work, please read
[MODERNIZATION.md](MODERNIZATION.md) so changes land on the right phase.
