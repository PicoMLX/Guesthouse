// swift-tools-version: 6.3

import PackageDescription

// Concurrency posture: this package keeps the nonisolated default. Its types are shared
// between the sandboxed GUI (which opts into MainActor default isolation) and the
// GuesthouseRuntime XPC service, so they must be Sendable and must not assume any actor.
// MemberImportVisibility matches the app target so warnings are consistent across targets.
let coreSwiftSettings: [SwiftSetting] = [
    .defaultIsolation(nil),
    .enableUpcomingFeature("MemberImportVisibility"),
]

let package = Package(
    name: "GuesthouseCore",
    platforms: [
        .macOS(.v26)
    ],
    products: [
        .library(
            name: "GuesthouseCore",
            targets: ["GuesthouseCore"]
        ),
    ],
    targets: [
        .target(
            name: "GuesthouseCore",
            swiftSettings: coreSwiftSettings
        ),
        .testTarget(
            name: "GuesthouseCoreTests",
            dependencies: ["GuesthouseCore"],
            swiftSettings: coreSwiftSettings
        ),
    ],
    swiftLanguageModes: [.v6]
)
