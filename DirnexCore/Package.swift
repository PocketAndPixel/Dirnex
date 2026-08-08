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
        // The system libarchive's declarations. macOS ships the dylib and the SDK ships its link
        // stub, so this adds no dependency — it is the only way to hand libarchive a passphrase
        // that never becomes a `ps`-readable argument. See `CArchiveShim/include/shim.h` for why
        // the encrypted path departs from §2's "bsdtar over libarchive".
        .target(
            name: "CArchiveShim",
            linkerSettings: [.linkedLibrary("archive")]
        ),
        .target(
            name: "DirnexCore",
            dependencies: ["CArchiveShim"]
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
