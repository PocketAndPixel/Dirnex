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
            dependencies: ["DirnexCore"],
            // Real bytes, not a hand-built imitation: a `.DS_Store` written by the system itself
            // when files were trashed from a scratch volume. A fixture a test *constructs* would
            // only prove the reader agrees with the test's own idea of the format.
            resources: [.copy("Fixtures")]
        )
    ],
    swiftLanguageModes: [.v6]
)
