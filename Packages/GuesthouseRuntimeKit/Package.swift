// swift-tools-version: 6.3

import PackageDescription

// Process execution and VM runtime adapters. Linked only by the GuesthouseRuntime XPC service; the
// app target must never import this package (MVP-PLAN.md §3: keep process-launch
// implementations in the runtime rather than exposing a generic execution API to the UI).
// Same concurrency posture as GuesthouseCore: nonisolated by default, Sendable types.
let kitSwiftSettings: [SwiftSetting] = [
    .defaultIsolation(nil),
    .enableUpcomingFeature("MemberImportVisibility"),
]

let package = Package(
    name: "GuesthouseRuntimeKit",
    platforms: [
        .macOS(.v26)
    ],
    products: [
        .library(
            name: "GuesthouseRuntimeKit",
            targets: ["GuesthouseRuntimeKit"]
        ),
    ],
    dependencies: [
        .package(path: "../GuesthouseCore")
    ],
    targets: [
        .target(
            name: "GuesthouseRuntimeKit",
            dependencies: [
                .product(name: "GuesthouseCore", package: "GuesthouseCore")
            ],
            swiftSettings: kitSwiftSettings
        ),
        .testTarget(
            name: "GuesthouseRuntimeKitTests",
            dependencies: ["GuesthouseRuntimeKit"],
            swiftSettings: kitSwiftSettings
        ),
    ],
    swiftLanguageModes: [.v6]
)
