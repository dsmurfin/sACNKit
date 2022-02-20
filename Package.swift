// swift-tools-version:5.5
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "sACNKit",
    platforms: [
        .iOS(.v10),
        .macOS(.v10_14),
    ],
    products: [
        .library(
            name: "sACNKit",
            targets: ["sACNKit"]),
    ],
    dependencies: [
        .package(url: "https://github.com/robbiehanson/CocoaAsyncSocket", from: "7.6.5")
    ],
    targets: [
        .target(
            name: "sACNKit",
            dependencies: []),
        .testTarget(
            name: "sACNKitTests",
            dependencies: ["sACNKit"]),
    ]
)
