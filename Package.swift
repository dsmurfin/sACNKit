// swift-tools-version: 6.2
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

// Phase 2 stages strict concurrency checking at `targeted` while remaining in Swift 5 language
// mode (warnings only). Removed in Phase 4 when Swift 6 language mode (equivalent to `complete`)
// is enabled (see MODERNIZATION.md).
let strictConcurrencySettings: [SwiftSetting] = [
    .enableExperimentalFeature("StrictConcurrency=targeted")
]

let package = Package(
    name: "sACNKit",
    platforms: [
        .iOS(.v17),
        .macOS(.v14),
        .tvOS(.v17),
        .visionOS(.v1),
    ],
    products: [
        .library(
            name: "sACNKit",
            targets: ["sACNKit"])
    ],
    dependencies: [
        .package(url: "https://github.com/robbiehanson/CocoaAsyncSocket", from: "7.6.5")
    ],
    targets: [
        .target(
            name: "sACNKit",
            dependencies: ["CocoaAsyncSocket"],
            swiftSettings: strictConcurrencySettings),
        .testTarget(
            name: "sACNKitTests",
            dependencies: ["sACNKit"],
            swiftSettings: strictConcurrencySettings),
    ],
    // Phase 1 keeps the existing GCD/delegate sources compiling by staying in Swift 5 language
    // mode. Strict concurrency / Swift 6 mode is adopted in Phases 2 and 4 (see MODERNIZATION.md).
    swiftLanguageModes: [.v5]
)
