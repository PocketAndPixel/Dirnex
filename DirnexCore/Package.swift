// swift-tools-version: 6.0
import PackageDescription

// DirnexCore — the headless, testable heart of Dirnex.
//
// Rule (see PLAN.md §2): if it touches bytes, it lives here and has tests.
// The app target is a thin UI client over this package. Zero AppKit imports.
let package = Package(
    name: "DirnexCore",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .library(name: "DirnexCore", targets: ["DirnexCore"])
    ],
    targets: [
        .target(
            name: "DirnexCore"
        ),
        .testTarget(
            name: "DirnexCoreTests",
            dependencies: ["DirnexCore"]
        )
    ],
    swiftLanguageModes: [.v6]
)
