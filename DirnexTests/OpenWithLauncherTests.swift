import AppKit
import DirnexCore
import Foundation
import Testing

@testable import Dirnex

/// The AppKit shell over `OpenWithApplications` (PLAN.md §M6 "'Open With' submenu"). The *rule* —
/// intersection, promotion, ordering — is the core's and is tested hermetically there; what needs
/// covering here is the part that can only be checked against a real Mac: that LaunchServices and
/// the bundles on this disk are read the way the menu needs them.
@Suite("OpenWith launcher")
@MainActor
struct OpenWithLauncherTests {
    /// A row standing for a real file on this disk. The launcher takes **rows** rather than URLs
    /// since M24 Slice 3, because half of a selection may have no file to ask about — the typing of
    /// a row that is not here is covered in `HandoffMaterializeTests`.
    private func row(at url: URL) -> FileEntry {
        FileEntry(
            path: .local(url.path),
            name: url.lastPathComponent,
            kind: .file,
            byteSize: 5,
            modificationDate: Date(timeIntervalSince1970: 1_700_000_000),
            creationDate: Date(timeIntervalSince1970: 1_700_000_000),
            isHidden: false,
            permissions: 0o644,
            inode: 3
        )
    }

    @Test("an application is named the way a menu should show it, not by its filename")
    func referenceUsesBundleDisplayName() {
        // The trap this pins: `localizedName` and `FileManager.displayName` both answer
        // "TextEdit.app" whenever the user has Finder's hide-extensions off, so a menu built from
        // either reads ".app" down the whole list. The bundle's own name never carries it.
        let url = URL(fileURLWithPath: "/System/Applications/TextEdit.app")
        let reference = OpenWithLauncher.reference(to: url)
        #expect(!reference.displayName.isEmpty)
        #expect(!reference.displayName.hasSuffix(".app"))
        #expect(reference.bundleIdentifier == "com.apple.TextEdit")
        #expect(reference.bundlePath == "/System/Applications/TextEdit.app")
        // The name is the *localized* one, and the test target inherits whatever `AppleLanguages`
        // Dirnex is pinned to (docs/NOTES.md) — Apple ships TextEdit as «Мініредактор» in
        // Ukrainian. So pin the English literal under exactly the condition that makes it the
        // right answer: the bundle resolving to its English localization.
        let isEnglish = Bundle(url: url)?.preferredLocalizations.first?.hasPrefix("en") == true
        if isEnglish {
            #expect(reference.displayName == "TextEdit")
        }
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

        let candidates = OpenWithLauncher.candidates(for: [row(at: url)])
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
        #expect(OpenWithLauncher.candidates(for: [row(at: url)]).isEmpty)
    }

    @Test("a file that has been deleted offers nothing rather than guessing")
    func candidatesForAVanishedFile() {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("dirnex-openwith-gone-\(UUID().uuidString).txt")
        // The pane lists, the user right-clicks, the file is gone in between: it has no type, so the
        // core's "no type means nothing opens it" rule reaches this from a real path.
        #expect(OpenWithLauncher.candidates(for: [row(at: url)]).isEmpty)
    }
}
