// swift-tools-version: 6.2
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

// Phase 4 (PR5) turns on Swift 6 language mode (equivalent to `complete` concurrency), so the
// `StrictConcurrency=targeted` experimental flag of Phases 2-3 is dropped. Default actor isolation is
// deliberately left `nonisolated` (no `.defaultIsolation(MainActor.self)`): each component is a Swift
// `actor` that supplies its own event-loop isolation, so a package-wide MainActor default would be wrong.
// Two upcoming features are adopted early: `NonisolatedNonsendingByDefault` (SE-0461 - a nonisolated async
// function runs on the caller's executor rather than hopping to the global one, which suits the socket I/O
// that already lives on the owning actor's event loop) and `InferIsolatedConformances` (SE-0470).
//
// `.treatAllWarnings(as: .error)` (Phase 3) keeps warnings-as-errors per-target (applying only to our own
// targets, not dependencies like swift-nio - see docs/modernization/phase-3.md).
let sharedSwiftSettings: [SwiftSetting] = [
    .treatAllWarnings(as: .error),
    .enableUpcomingFeature("NonisolatedNonsendingByDefault"),
    .enableUpcomingFeature("InferIsolatedConformances"),
]

let package = Package(
    name: "sACNKit",
    platforms: [
        .iOS(.v18),
        .macOS(.v15),
        .tvOS(.v18),
        .visionOS(.v2),
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
    // Swift 6 language mode (Phase 4 PR5). The whole stack is actors on a custom event-loop executor;
    // see MODERNIZATION.md / docs/modernization/phase-4.md.
    swiftLanguageModes: [.v6]
)
