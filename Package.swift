// swift-tools-version: 6.0
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

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
            dependencies: ["CocoaAsyncSocket"]),
        .testTarget(
            name: "sACNKitTests",
            dependencies: ["sACNKit"]),
    ],
    // Phase 1 keeps the existing GCD/delegate sources compiling by staying in Swift 5 language
    // mode. Strict concurrency / Swift 6 mode is adopted in Phases 2 and 4 (see MODERNIZATION.md).
    swiftLanguageModes: [.v5]
)
