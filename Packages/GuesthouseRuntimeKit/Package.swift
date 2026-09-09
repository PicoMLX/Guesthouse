// swift-tools-version: 6.3
import PackageDescription

let runtimeSwiftSettings: [SwiftSetting] = [
    .defaultIsolation(nil),
    .enableUpcomingFeature("MemberImportVisibility"),
]

// Runtime-only code. The GUI must not import or link this product (MVP-PLAN.md §3).
let package = Package(
    name: "GuesthouseRuntimeKit",
    platforms: [.macOS(.v26)],
    products: [.library(name: "GuesthouseRuntimeKit", targets: ["GuesthouseRuntimeKit"])],
    dependencies: [.package(path: "../GuesthouseCore")],
    targets: [
        // Pure C owns the retained native requirement for process lifetime; no ARC/unsafe
        // compiler flags are needed when this product is consumed by the Xcode project.
        .target(name: "GuesthouseRuntimeAuthentication"),
        .target(
            name: "GuesthouseRuntimeKit",
            dependencies: ["GuesthouseRuntimeAuthentication"],
            swiftSettings: runtimeSwiftSettings
        ),
        .testTarget(
            name: "GuesthouseRuntimeKitTests",
            dependencies: [
                "GuesthouseRuntimeKit", "GuesthouseRuntimeAuthentication",
                .product(name: "GuesthouseCore", package: "GuesthouseCore"),
            ],
            swiftSettings: runtimeSwiftSettings
        ),
    ],
    swiftLanguageModes: [.v6]
)
