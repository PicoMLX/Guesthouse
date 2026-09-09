// swift-tools-version: 6.3
import PackageDescription

// GUI-safe native transport, separately testable without launching the app. No RuntimeKit,
// process execution, provider adapters, credentials or host mutations (MVP-PLAN.md §3).
let settings: [SwiftSetting] = [.defaultIsolation(nil), .enableUpcomingFeature("MemberImportVisibility")]
let package = Package(
    name: "GuesthouseClientKit", platforms: [.macOS(.v26)],
    products: [.library(name: "GuesthouseClientKit", targets: ["GuesthouseClientKit"])],
    dependencies: [.package(path: "../GuesthouseCore")],
    targets: [
        .target(name: "GuesthouseClientKit", dependencies: [.product(name: "GuesthouseCore", package: "GuesthouseCore")], swiftSettings: settings),
        .testTarget(name: "GuesthouseClientKitTests", dependencies: ["GuesthouseClientKit", .product(name: "GuesthouseCore", package: "GuesthouseCore")], swiftSettings: settings),
    ], swiftLanguageModes: [.v6]
)
