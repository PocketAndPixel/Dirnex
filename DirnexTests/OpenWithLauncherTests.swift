import AppKit
import DirnexCore
import Testing

@testable import Dirnex

/// The AppKit shell over `OpenWithApplications` (PLAN.md §M6 "'Open With' submenu"). The *rule* —
/// intersection, promotion, ordering — is the core's and is tested hermetically there; what needs
/// covering here is the part that can only be checked against a real Mac: that LaunchServices and
/// the bundles on this disk are read the way the menu needs them.
@Suite("OpenWith launcher")
@MainActor
struct OpenWithLauncherTests {
    @Test("an application is named the way a menu should show it, not by its filename")
    func referenceUsesBundleDisplayName() {
        // The trap this pins: `localizedName` and `FileManager.displayName` both answer
        // "TextEdit.app" whenever the user has Finder's hide-extensions off, so a menu built from
        // either reads ".app" down the whole list. The bundle's own name never carries it.
        let reference = OpenWithLauncher.reference(
            to: URL(fileURLWithPath: "/System/Applications/TextEdit.app")
        )
        #expect(reference.displayName == "TextEdit")
        #expect(!reference.displayName.hasSuffix(".app"))
        #expect(reference.bundleIdentifier == "com.apple.TextEdit")
        #expect(reference.bundlePath == "/System/Applications/TextEdit.app")
    }

    @Test("a bundle with no Info.plist name falls back to its filename without the extension")
    func referenceFallsBackToFilename() {
        let reference = OpenWithLauncher.reference(
            to: URL(fileURLWithPath: "/nonexistent/Ghost.app")
        )
        #expect(reference.displayName == "Ghost")
        #expect(reference.bundleIdentifier == nil)
    }

    @Test("a real text file offers a real application list, default first")
    func candidatesForATextFile() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("dirnex-openwith-\(UUID().uuidString).txt")
        try "hello".write(to: url, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: url) }

        let candidates = OpenWithLauncher.candidates(for: [url])
        // Asserted against the machine rather than a fixed list: which editors are installed is not
        // this test's business, but *some* app opens plain text on any Mac, and the promoted one
        // must be the one a double-click would use.
        #expect(!candidates.isEmpty)
        let byDoubleClick = NSWorkspace.shared.urlForApplication(toOpen: url)
        #expect(candidates.defaultApplication?.bundlePath == byDoubleClick?.path)
        #expect(
            !candidates.others.contains { $0.bundlePath == candidates.defaultApplication?.bundlePath }
        )
    }

    @Test("a file no application claims offers nothing")
    func candidatesForAnUnclaimedFile() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("dirnex-openwith-\(UUID().uuidString).zzzqqq")
        try "x".write(to: url, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: url) }

        // LaunchServices types this dynamically (`dyn.…`) and registers nothing against it. The menu
        // still offers Other…, which is the app layer's job, not this list's.
        #expect(OpenWithLauncher.candidates(for: [url]).isEmpty)
    }

    @Test("a file that has been deleted offers nothing rather than guessing")
    func candidatesForAVanishedFile() {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("dirnex-openwith-gone-\(UUID().uuidString).txt")
        // The pane lists, the user right-clicks, the file is gone in between: it has no type, so the
        // core's "no type means nothing opens it" rule reaches this from a real path.
        #expect(OpenWithLauncher.candidates(for: [url]).isEmpty)
    }
}
