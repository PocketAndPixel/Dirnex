import AppKit
import DirnexCore
import Foundation
import Testing

@testable import Dirnex

/// Where "Archive Name Encoding…" is offered — the way *in* to the chooser that does not require a
/// gesture to have failed first (PLAN.md §M27).
///
/// Before it existed the chooser was reachable only from a refusal: F8, a paste, an F5 copy-out.
/// Somebody who merely wanted to **read** the names — which is what a pane full of `���.txt` makes
/// you want — had no route at all, and that is not a state a menu can be in. The other way to close
/// it would have been a prompt on entering such an archive, and that is the thing docs/NOTES.md
/// keeps warning about: a sheet raised by a gesture nobody made.
///
/// Everything below the assertion is **real**: the fixture is a genuine 218-byte zip with CP866
/// names and the UTF-8 flag clear, `ArchiveMounter` spawns the real `bsdtar` to list it, the pane
/// routes through a real `CompositeBackend`, and the answers come from the real `validateMenuItem`
/// rather than from a second copy of the predicate — which is the whole point, since a validator
/// carrying its own copy of a rule is how a working command ends up grayed out (docs/NOTES.md
/// ▸ AppKit, the size-bar and `canGoToParent` lessons).
///
/// **The action is deliberately not driven, and the reason is a hang rather than a failure.**
/// `chooseArchiveNameEncoding` ends in `ArchiveNameEncodingPrompt.ask`, which with no window falls
/// back to `runModal()` — correct, since it is a gesture somebody is waiting on (docs/NOTES.md
/// ▸ Testing, "who is waiting?") — so a pane that wrongly got past the guard would put an app-modal
/// alert in front of a headless test host and wedge the run instead of failing it. That is worse
/// than no control at all. What covers it instead is that the action and the validator read the
/// *same* property, `archiveAwaitingNameEncoding`, which is asserted here directly.
@MainActor
@Suite("Archive name encoding's reach")
struct ArchiveNameEncodingReachTests {
    // MARK: - Fixtures

    /// A real zip on disk. `legacy` holds `Панорама.txt` in **CP866** with general-purpose bit 11
    /// clear beside an ASCII `plain.txt`; `modern` is packed here and so carries UTF-8 names with
    /// the flag set — the narrowness control, and the only thing that stops "offer it in every
    /// archive" from passing this suite.
    private struct Fixture {
        let root: URL
        let path: String

        init(legacy: Bool) throws {
            root = FileManager.default.temporaryDirectory
                .appendingPathComponent("dirnex_encoding_reach_\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            path = root.appendingPathComponent("archive.zip").path
            if legacy {
                let bytes = try #require(
                    Data(base64Encoded: Self.legacyCodePageZip, options: .ignoreUnknownCharacters)
                )
                try bytes.write(to: URL(fileURLWithPath: path))
            } else {
                try Self.packModernArchive(at: path, under: root)
            }
        }

        func cleanup() { try? FileManager.default.removeItem(at: root) }

        /// Packed with the app's own spawn site so the control meets the *same* `bsdtar` under the
        /// *same* pinned locale the legacy fixture does — a hand-written zip would differ in more
        /// than the thing under test.
        private static func packModernArchive(at path: String, under root: URL) throws {
            let source = root.appendingPathComponent("source", isDirectory: true)
            try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
            // Non-ASCII on purpose: an all-ASCII control would pass whatever the rule is.
            for name in ["Панорама.txt", "plain.txt"] {
                try Data("x".utf8).write(to: source.appendingPathComponent(name))
            }
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/bsdtar")
            process.environment = ChildProcessLocale.inherited()
            process.currentDirectoryURL = source
            process.arguments = ["-c", "-f", path, "--format", "zip", "."]
            try process.run()
            process.waitUntilExit()
        }

        /// The same 218 bytes `ArchiveNameEncodingRewriteTests` mints — two stored entries, one
        /// named in CP866 as Windows tools wrote them for years.
        private static let legacyCodePageZip = """
        UEsDBBQAAAAAAAAAIQCDFtyMAQAAAAEAAAAMAAAAj6CtruCgrKAudHh0eFBLAwQUAAAAAAAAACEA
        gxbcjAEAAAABAAAACQAAAHBsYWluLnR4dHhQSwECFAMUAAAAAAAAACEAgxbcjAEAAAABAAAADAAA
        AAAAAAAAAAAAgAEAAAAAj6CtruCgrKAudHh0UEsBAhQDFAAAAAAAAAAhAIMW3IwBAAAAAQAAAAkA
        AAAAAAAAAAAAAIABKwAAAHBsYWluLnR4dFBLBQYAAAAAAgACAHEAAABTAAAAAAA=
        """
    }

    /// A pane standing inside `archivePath`, having really listed it.
    ///
    /// The listing is what puts the mount in the composite, and the mount is what the peek reads —
    /// so this is also the fixture's own precondition: a pane that never listed the archive would
    /// answer `false` for the honest reason that nothing has been read.
    private static func paneInsideArchive(
        at archivePath: String, declaring encoding: ArchiveNameEncoding? = nil
    ) throws -> PanelViewController {
        let composite = CompositeBackend(local: LocalBackend())
        if let encoding {
            composite.declareNameEncoding(encoding, forArchiveAt: archivePath)
        }
        let root = VFSPath(backend: .archive(forArchiveAt: archivePath), path: "/")
        let entries = try composite.listDirectory(at: root)
        let pane = PanelViewController(
            backend: composite, restoration: nil, defaultPath: root, restorationKey: nil
        )
        pane.panel = Panel(model: DirectoryModel(
            listing: DirectoryListing(path: root, entries: entries)
        ))
        return pane
    }

    private static func paneOnLocalDirectory() -> PanelViewController {
        let path = VFSPath.local(NSHomeDirectory())
        let pane = PanelViewController(
            backend: CompositeBackend(local: LocalBackend()),
            restoration: nil,
            defaultPath: path,
            restorationKey: nil
        )
        pane.panel = Panel(model: DirectoryModel(
            listing: DirectoryListing(path: path, entries: [])
        ))
        return pane
    }

    private static func menuItem() -> NSMenuItem {
        let item = NSMenuItem()
        item.action = #selector(PanelViewController.chooseArchiveNameEncoding(_:))
        return item
    }

    // MARK: - The reach

    @Test("an archive whose names did not decode offers the chooser")
    func legacyArchiveOffersTheChooser() throws {
        let fixture = try Fixture(legacy: true)
        defer { fixture.cleanup() }
        let pane = try Self.paneInsideArchive(at: fixture.path)

        // The row the user is looking at, which is what makes this the reported state rather than
        // an abstraction: one name survived and one did not.
        let names = pane.panel.displayedEntries.map(\.name)
        #expect(names.contains("plain.txt"), "listed \(names)")
        #expect(!names.contains("Панорама.txt"), "listed \(names)")

        #expect(pane.archiveAwaitingNameEncoding == fixture.path)
        #expect(pane.validateMenuItem(Self.menuItem()))
    }

    /// The narrowness control. Without it, "offer the chooser" would pass just as well implemented
    /// as "in every archive", and the item would be live in a pane there is nothing wrong with.
    @Test("an archive whose names are UTF-8 does not")
    func modernArchiveDoesNotOfferTheChooser() throws {
        let fixture = try Fixture(legacy: false)
        defer { fixture.cleanup() }
        let pane = try Self.paneInsideArchive(at: fixture.path)

        // The precondition, asserted rather than assumed: this archive really does list the name
        // the other one loses, so the difference between the two panes is the encoding and not the
        // fixture failing to pack.
        #expect(pane.panel.displayedEntries.map(\.name).contains("Панорама.txt"))
        #expect(pane.archiveAwaitingNameEncoding == nil)
        #expect(!pane.validateMenuItem(Self.menuItem()))
    }

    /// **A declaration already in force keeps the item live**, and this is the half that is easy to
    /// leave out.
    ///
    /// A wrong code page does not fail — it produces well-formed nonsense, and can be *invisibly*
    /// wrong (CP1251 reads this fixture's separators as no-break spaces and soft hyphens). So no
    /// refusal will ever be raised to offer the chooser a second time, and gated on the unreadable
    /// half alone, changing your mind would be impossible: the names decode, the item grays out,
    /// and the only way back is to quit.
    @Test("an archive that has already been declared can be declared again")
    func declaredArchiveStillOffersTheChooser() throws {
        let fixture = try Fixture(legacy: true)
        defer { fixture.cleanup() }
        // Declared wrongly on purpose — a fitting code page that is not the right one, which is
        // exactly the state somebody would want to correct.
        let pane = try Self.paneInsideArchive(at: fixture.path, declaring: .cp1251)

        let names = pane.panel.displayedEntries.map(\.name)
        #expect(!names.contains { $0.contains("\u{FFFD}") }, "listed \(names)")
        #expect(!names.contains("Панорама.txt"), "CP1251 should not read this archive right")

        #expect(pane.archiveAwaitingNameEncoding == fixture.path)
        #expect(pane.validateMenuItem(Self.menuItem()))
    }

    @Test("a pane that is not in an archive does not offer it")
    func localDirectoryDoesNotOfferTheChooser() {
        let pane = Self.paneOnLocalDirectory()
        #expect(pane.archiveAwaitingNameEncoding == nil)
        #expect(!pane.validateMenuItem(Self.menuItem()))
    }

    // MARK: - The wiring

    /// The item is in the **built** menu, not merely well-formed in the builder.
    ///
    /// docs/NOTES.md records the negative control that showed the difference: an assertion over
    /// `MainMenuBuilder.commandItem(for:)` keeps passing for an item that is in no menu at all, so
    /// the built tree is flattened and searched for the *selector*.
    @Test("the File menu carries it, and the palette can run it")
    func theCommandIsWired() throws {
        let items = MainMenuBuilder.build().items
            .flatMap { item in [item] + (item.submenu?.items ?? []) }
        #expect(items.contains { $0.action == #selector(
            PanelViewController.chooseArchiveNameEncoding(_:)
        ) })
        #expect(CommandBinding.selector(for: "file.archiveNameEncoding") == #selector(
            PanelViewController.chooseArchiveNameEncoding(_:)
        ))
        // A registry command with no catalog entry falls back to English rather than failing, so
        // its presence in the registry is what the palette and the menu title both rest on.
        #expect(CommandCatalog.command(for: "file.archiveNameEncoding") != nil)
    }
}
