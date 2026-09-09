import AppKit
import DirnexCore
import Foundation
import Testing

@testable import Dirnex

/// The declaration's remaining call sites, driven rather than read (PLAN.md §M27 listed all three as
/// threaded and never run).
///
/// Each one passes `declaredNameEncoding(forArchiveAt:)` into something that then has to do the
/// right thing with it, and "it is threaded" is a claim about the argument rather than about the
/// result — the shape docs/NOTES.md records for every seam whose default is *also* its good answer.
/// What is measured here is the result: a nested archive entered by a name only the declaration can
/// spell, a rewrite that puts an edited member back into an archive nobody could otherwise name, and
/// a preview cache asked for a member under both spellings.
@MainActor
@Suite("Where a declared code page has to arrive")
struct ArchiveNameEncodingCallSiteTests {
    // `nonisolated` so the fixture's own initializer, which is not on the main actor, can read
    // them.
    private nonisolated static let cyrillic = "Панорама.txt"
    private nonisolated static let nestedArchiveName = "Архив.zip"

    // MARK: - Fixtures

    /// A legacy outer archive, optionally holding a **nested** archive under a code-page name.
    private struct Fixture {
        let root: URL
        let path: String

        init(nesting: Bool = false) throws {
            root = FileManager.default.temporaryDirectory
                .appendingPathComponent("legacy_call_site_\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            path = root.appendingPathComponent("outer.zip").path
            var members: [LegacyNameZip.Member] = [.text("plain.txt", "readable contents")]
            if nesting {
                members.append(
                    LegacyNameZip.Member(name: nestedArchiveName, contents: try Self.innerArchive())
                )
            } else {
                members.append(.text(cyrillic, "original contents"))
            }
            try LegacyNameZip.write(members, to: path)
        }

        /// An ordinary UTF-8 zip holding one file — what goes *inside* the legacy one, so the only
        /// thing standing between a pane and its contents is the outer archive's names.
        private static func innerArchive() throws -> Data {
            let staging = FileManager.default.temporaryDirectory
                .appendingPathComponent("legacy_inner_\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: staging) }
            let source = staging.appendingPathComponent("source", isDirectory: true)
            try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
            try Data("nested contents".utf8).write(to: source.appendingPathComponent("note.txt"))
            let archive = staging.appendingPathComponent("inner.zip").path
            try EncryptedArchiveWriter.write(
                items: try ArchiveSourceEnumerator.items(
                    inDirectory: source.path, names: ["note.txt"]
                ),
                toArchiveAt: archive,
                encryption: .none,
                passphrase: nil
            )
            return try Data(contentsOf: URL(fileURLWithPath: archive))
        }

        func cleanup() { try? FileManager.default.removeItem(at: root) }
    }

    /// A real pane standing inside `archivePath`, with the code page declared and its rows already
    /// listed through the real backend.
    ///
    /// The listing is **seeded rather than awaited**, and the view is deliberately not loaded. What
    /// is under test is `beginNestedArchiveEntry`, which reads `panel.path` and the entry it is
    /// handed and touches no table — so an unloaded pane measures the same thing (the
    /// `RenameReachTests` lesson cuts the other way here: it is a flow that *reads* the table which
    /// an unloaded pane cannot judge). What it buys is the whole of the pane's own first listing and
    /// its table's share of the main-actor layout every other suite is queued behind: measured in a
    /// full run, the gesture's wait went from **17–22 s** to under one, against a 30 s budget it had
    /// been leaving no headroom in.
    private static func pane(
        inside archivePath: String, declaring encoding: ArchiveNameEncoding?
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
        // Deafened so another suite writing a preference cannot repaint this one; every observer
        // here is selector-based and installed once.
        NotificationCenter.default.removeObserver(pane)
        return pane
    }

    // MARK: - Entering a nested archive

    /// **⏎ on an archive inside a legacy archive**, driven through the shipped
    /// `beginNestedArchiveEntry` — the extraction, the temp mount and the navigation.
    ///
    /// The member's name exists only because a code page was declared, so this is the one gesture
    /// that cannot be half-right: the extraction is asked for a path the outer archive spells in
    /// CP866, and a declaration that failed to arrive would ask for `���.zip` and land nothing.
    @Test("a nested archive named in a code page can be entered")
    func nestedArchiveEntryCarriesTheDeclaration() async throws {
        let fixture = try Fixture(nesting: true)
        defer { fixture.cleanup() }
        let pane = try Self.pane(inside: fixture.path, declaring: .cp866)

        let member = try #require(
            pane.panel.displayedEntries.first { $0.name == Self.nestedArchiveName },
            "the outer archive never listed \(Self.nestedArchiveName)"
        )
        pane.beginNestedArchiveEntry(for: member)

        try await settleUntil { pane.panel.displayedEntries.map(\.name) == ["note.txt"] }
        #expect(pane.panel.displayedEntries.map(\.name) == ["note.txt"])
        // And it really is *inside* something else — a mount of the extracted copy, not the outer
        // archive it came from.
        let mounted = pane.panel.path.backend.archivePath
        #expect(mounted != nil && mounted != fixture.path, "mounted \(mounted ?? "nothing")")
    }

    /// The narrowness control. Undeclared, the pane cannot name the row at all, so there is nothing
    /// to press ⏎ on — which is what stops "enter the nested archive" from passing implemented as
    /// "enter whatever is under the cursor".
    @Test("undeclared, the nested archive is not even a row anybody can name")
    func undeclaredNestedArchiveIsUnnameable() throws {
        let fixture = try Fixture(nesting: true)
        defer { fixture.cleanup() }
        let pane = try Self.pane(inside: fixture.path, declaring: nil)

        let names = pane.panel.displayedEntries.map(\.name)
        #expect(names.contains("plain.txt"), "listed \(names)")
        #expect(!names.contains(Self.nestedArchiveName), "listed \(names)")
    }

    // MARK: - The write-back's rewrite

    /// **What the archive write-back batch hands to**, under a declaration.
    ///
    /// `ArchiveWriter.add` is the primitive behind writing an edited member back, and the batch's
    /// own call site is one line — `pane.declaredNameEncoding(forArchiveAt:)` — in front of it. The
    /// gesture around that line is **not drivable headlessly and the reason is not shyness**: it
    /// opens with `confirmArchiveWriteBack`, whose `sheetAnswer(over:whenUnasked: .cancel)` answers
    /// *cancel* when there is no window (correctly — a watcher raised it, so a window that has gone
    /// away has nobody to ask), and with a window it is a real sheet in front of a test host nobody
    /// is looking at. So what is reachable is everything after the answer, which is all of the part
    /// the declaration reaches.
    ///
    /// `ArchiveNameEncodingRewriteTests` covers `delete` this way; `add` is the half a write-back
    /// takes, and until now nothing had run it against an archive whose names are in a code page.
    @Test("an edited member is written back into an archive nobody could otherwise name")
    func addCarriesTheDeclaration() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }

        // The edited copy an editor left behind, under the member's real name.
        let edited = fixture.root.appendingPathComponent(Self.cyrillic)
        try Data("edited contents".utf8).write(to: edited)

        try ArchiveWriter.add(
            [ArchiveMutation.Addition(localPath: edited.path, innerDirectory: "/")],
            ofArchiveAt: fixture.path,
            undo: .none,
            nameEncoding: .cp866
        )

        // Read back with **nothing** declared: the repack goes through `bsdtar`, which writes UTF-8
        // names with the zip's flag set, so an archive that needed a declaration a moment ago no
        // longer does. That this read succeeds at all is half the measurement.
        let toc = try ArchiveMounter.readTableOfContents(ofArchiveAt: fixture.path)
        #expect(toc.children(inDirectory: "/").map(\.name).sorted()
            == ["plain.txt", Self.cyrillic])

        let extraction = try ArchiveExtractor.extract(
            innerPaths: ["/" + Self.cyrillic, "/plain.txt"], fromArchiveAt: fixture.path
        )
        defer { try? FileManager.default.removeItem(at: extraction.directory) }
        let contents = extraction.extractedPaths.map {
            (
                ($0 as NSString).lastPathComponent,
                (try? String(contentsOfFile: $0, encoding: .utf8)) ?? "<unreadable>"
            )
        }
        #expect(
            contents.contains { $0 == (Self.cyrillic, "edited contents") },
            "the edit did not land: \(contents)"
        )
        // The member nobody edited has to survive a rewrite that is a whole-container pass.
        #expect(
            contents.contains { $0 == ("plain.txt", "readable contents") },
            "the untouched member did not survive: \(contents)"
        )
    }

    /// And the refusal is unchanged, **before the archive is touched** — which is what makes
    /// offering the chooser afterwards a safe thing to do rather than a recovery.
    @Test("undeclared, the write-back refuses and leaves the archive alone")
    func undeclaredAddIsRefusedAndChangesNothing() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let before = try Data(contentsOf: URL(fileURLWithPath: fixture.path))
        let edited = fixture.root.appendingPathComponent(Self.cyrillic)
        try Data("edited contents".utf8).write(to: edited)

        var thrown: Error?
        do {
            try ArchiveWriter.add(
                [ArchiveMutation.Addition(localPath: edited.path, innerDirectory: "/")],
                ofArchiveAt: fixture.path,
                undo: .none
            )
        } catch { thrown = error }

        let refusal = try #require(thrown)
        #expect(PanelViewController.isNameEncodingRefusal(refusal), "refused with \(refusal)")
        let after = try Data(contentsOf: URL(fileURLWithPath: fixture.path))
        #expect(before == after, "a refused rewrite must not have altered the archive")
    }

    // MARK: - The preview cache

    /// **A preview cached before a declaration**, which PLAN.md carried as an argument rather than a
    /// measurement: entries are keyed on the member's *inner path*, and a declaration changes what
    /// that path is, so an entry minted while the names were mojibake should be unreachable
    /// afterwards rather than stale-and-served.
    ///
    /// Measured here, it is better than unreachable — such an entry cannot be **minted** at all. The
    /// row a user could put the cursor on is named with U+FFFD substitutes, no member is called
    /// that, and the extraction refuses instead of caching something under a name that means
    /// nothing. So there is no stale entry to serve, at any point.
    @Test("a member nobody can name cannot be cached before the code page is declared")
    func theUnnameableMemberIsNeverCached() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let cache = ArchivePreviewCache()

        // The inner path exactly as the *pane* has it — taken from a real listing through the real
        // backend rather than spelled out here, since what is under test is what a cursor on that
        // row would ask for.
        let composite = CompositeBackend(local: LocalBackend())
        let rows = try composite.listDirectory(
            at: VFSPath(backend: .archive(forArchiveAt: fixture.path), path: "/")
        )
        let mojibake = try #require(
            rows.first { $0.name.contains("\u{FFFD}") }?.path.path,
            "the fixture should draw one row nobody can name"
        )
        let member = ArchiveMember(archivePath: fixture.path, innerPath: mojibake)

        var thrown: Error?
        do { _ = try await cache.extractedURL(for: member) } catch { thrown = error }
        let refusal = try #require(thrown)
        // The *reason* is the assertion, not the throw: reported as a damaged archive this row
        // would send the user looking for a corrupt file, where what it needs is the chooser.
        #expect(PanelViewController.isNameEncodingRefusal(refusal), "refused with \(refusal)")
        #expect(cache.cachedURL(for: member) == nil, "a refused extraction must cache nothing")
    }

    /// **F5 copy-out of that same row**, which HISTORY.md listed as a route to the chooser from the
    /// day the chooser shipped and which measured 2026-09-09 was not one.
    ///
    /// `bsdtar` cannot be handed a name it could not decode — the pane drew `���.txt`, which is what
    /// the extraction then asks for, and no member is called that — so nothing landed and the
    /// extractor reported `archiveExtractFailed`. `offerNameEncoding` matches on the *case*, so the
    /// gesture said "couldn't extract from the archive" and offered nothing, on the archive whose
    /// whole problem is a question nobody had been asked.
    @Test("an unnameable row refuses for its name rather than as a damaged archive")
    func copyOutOfAnUnnameableRowOffersTheChooser() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let composite = CompositeBackend(local: LocalBackend())
        let rows = try composite.listDirectory(
            at: VFSPath(backend: .archive(forArchiveAt: fixture.path), path: "/")
        )
        let mojibake = try #require(rows.first { $0.name.contains("\u{FFFD}") }?.path.path)

        var thrown: Error?
        do {
            _ = try ArchiveExtractor.extract(
                innerPaths: [mojibake], fromArchiveAt: fixture.path
            )
        } catch { thrown = error }

        let refusal = try #require(thrown)
        #expect(PanelViewController.isNameEncodingRefusal(refusal), "refused with \(refusal)")
    }

    /// The narrowness control, and without it "report the name refusal" would pass implemented as
    /// "report it whatever went wrong" — which would offer a code-page chooser over an archive whose
    /// names are perfectly fine and whose member is simply not there.
    @Test("a member missing from an ordinary archive is still a failed extraction")
    func aMissingMemberOfAnOrdinaryArchiveIsNotANameProblem() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ordinary_archive_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("source", isDirectory: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try Data("x".utf8).write(to: source.appendingPathComponent("one.txt"))
        let archive = root.appendingPathComponent("ordinary.zip").path
        try EncryptedArchiveWriter.write(
            items: try ArchiveSourceEnumerator.items(inDirectory: source.path, names: ["one.txt"]),
            toArchiveAt: archive, encryption: .none, passphrase: nil
        )

        var thrown: Error?
        do {
            _ = try ArchiveExtractor.extract(
                innerPaths: ["/not-there.txt"], fromArchiveAt: archive
            )
        } catch { thrown = error }

        let failure = try #require(thrown)
        #expect(!PanelViewController.isNameEncodingRefusal(failure), "refused with \(failure)")
    }

    /// The other half, and the one that says the cache is safe rather than merely empty: the member
    /// that **was** cachable before the declaration is still correct after it.
    ///
    /// A declaration changes how names are read and changes nothing about the file, so the bytes
    /// behind an ASCII member are the same bytes — and the identity check that drops extractions
    /// when the archive is replaced correctly does not fire, because it has not been.
    @Test("an ASCII member cached before the declaration is still served, and still right")
    func anASCIIMemberSurvivesTheDeclaration() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let cache = ArchivePreviewCache()
        let plain = ArchiveMember(archivePath: fixture.path, innerPath: "/plain.txt")

        let before = try await cache.extractedURL(for: plain)
        #expect(try String(contentsOf: before, encoding: .utf8) == "readable contents")

        // What declaring does to the caches it can reach — the mount is dropped, this one is not.
        let composite = CompositeBackend(local: LocalBackend())
        composite.declareNameEncoding(.cp866, forArchiveAt: fixture.path)

        #expect(cache.cachedURL(for: plain) == before, "the entry was dropped for no reason")
        let after = try await cache.extractedURL(for: plain, nameEncoding: .cp866)
        #expect(after == before, "re-extracted a member whose bytes cannot have changed")
        #expect(try String(contentsOf: after, encoding: .utf8) == "readable contents")
    }

    /// And once declared, the member that needed the declaration previews under its real name — a
    /// **different key**, so there was never a stale entry standing in its way.
    @Test("declared, the member previews under its real name")
    func theDeclaredMemberPreviews() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let cache = ArchivePreviewCache()
        let member = ArchiveMember(archivePath: fixture.path, innerPath: "/" + Self.cyrillic)

        #expect(cache.cachedURL(for: member) == nil)
        let url = try await cache.extractedURL(for: member, nameEncoding: .cp866)
        #expect(url.lastPathComponent == Self.cyrillic)
        #expect(try String(contentsOf: url, encoding: .utf8) == "original contents")
        #expect(cache.cachedURL(for: member) == url)
    }
}
