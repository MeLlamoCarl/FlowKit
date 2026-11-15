// swift-tools-version:5.9

import PackageDescription

let package = Package(
    name: "FlowKit",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .library(
            name: "FlowKit",
            targets: ["FlowKit"]
        )
    ],
    targets: [
        .target(name: "FlowKit"),
        .testTarget(
            name: "FlowKitTests",
            dependencies: ["FlowKit"]
        )
    ]
)
