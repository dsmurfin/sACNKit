// swift-tools-version: 6.2
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

// Phase 2 stages strict concurrency checking at `targeted` while remaining in Swift 5 language
// mode (warnings only). Removed in Phase 4 when Swift 6 language mode (equivalent to `complete`)
// is enabled (see MODERNIZATION.md).
//
// Phase 3 moves warnings-as-errors enforcement off the CI `-Xswiftc -warnings-as-errors` flag
// (which applies to every module, including dependencies like swift-nio) and into this per-target
// setting, which applies only to our own targets (see MODERNIZATION.md / docs/modernization/phase-3.md).
let sharedSwiftSettings: [SwiftSetting] = [
    .enableExperimentalFeature("StrictConcurrency=targeted"),
    .treatAllWarnings(as: .error),
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
        .package(url: "https://github.com/apple/swift-nio.git", from: "2.81.0")
    ],
    targets: [
        .target(
            name: "sACNKit",
            dependencies: [
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "NIOPosix", package: "swift-nio"),
                .product(name: "NIOFoundationCompat", package: "swift-nio"),
                .product(name: "NIOConcurrencyHelpers", package: "swift-nio"),
            ],
            swiftSettings: sharedSwiftSettings),
        .testTarget(
            name: "sACNKitTests",
            dependencies: ["sACNKit"],
            swiftSettings: sharedSwiftSettings),
    ],
    // Phase 1 keeps the existing GCD/delegate sources compiling by staying in Swift 5 language
    // mode. Strict concurrency / Swift 6 mode is adopted in Phases 2 and 4 (see MODERNIZATION.md).
    swiftLanguageModes: [.v5]
)
