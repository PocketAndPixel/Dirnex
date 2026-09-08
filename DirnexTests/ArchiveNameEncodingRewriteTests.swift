import Foundation
import Testing

@testable import Dirnex
@testable import DirnexCore

/// Rewriting an archive whose entry names are stored in a code page rather than UTF-8.
///
/// This is the claim the whole feature exists for, driven through the **real** `ArchiveWriter` — the
/// same extract → edit → repack → atomic-swap path F8 and paste take — because the gesture itself
/// ends in a chooser sheet and cannot be driven headlessly (docs/NOTES.md ▸ Live verification). What
/// is reachable is everything after the answer, which is all of the part that was refused.
///
/// The fixture is minted here rather than by anything in this repo: 218 bytes, two stored entries,
/// one named `Панорама.txt` in **CP866** with general-purpose bit 11 clear, as Windows tools wrote
/// them for years.
@Suite("Legacy code-page archive rewrite")
struct ArchiveNameEncodingRewriteTests {
    private static let cyrillic = "Панорама.txt"

    // MARK: - The refusal, unchanged

    /// The narrowness control, and the behaviour every other archive still gets: with no code page
    /// declared the rewrite refuses — **before touching the archive**, which is what makes offering
    /// the chooser afterwards a safe thing to do rather than a recovery.
    @Test("an undeclared legacy archive is still refused, and is left untouched")
    func undeclaredRewriteIsRefusedAndChangesNothing() throws {
        let archive = try Fixture()
        defer { archive.cleanup() }
        let before = try Data(contentsOf: URL(fileURLWithPath: archive.path))

        #expect(throws: EncryptedArchiveError.self) {
            try ArchiveWriter.delete(
                innerPaths: ["/plain.txt"], fromArchiveAt: archive.path, undo: .none
            )
        }
        let after = try Data(contentsOf: URL(fileURLWithPath: archive.path))
        #expect(before == after, "a refused rewrite must not have altered the archive")
    }

    // MARK: - The rewrite, once the code page is declared

    /// Delete one member of a legacy archive and keep the one nobody can otherwise name.
    ///
    /// The read-back is deliberately done with **no encoding declared**: the repack goes through
    /// `bsdtar`, which writes UTF-8 names with the zip's flag set, so an archive that could only be
    /// read with a declaration comes back readable by everything. That the assertion passes without
    /// the declaration it needed a moment ago is the measurement.
    @Test("a declared archive rewrites, keeping the name and upgrading the archive to UTF-8")
    func declaredRewriteKeepsTheNameAndUpgradesTheArchive() throws {
        let archive = try Fixture()
        defer { archive.cleanup() }

        try ArchiveWriter.delete(
            innerPaths: ["/plain.txt"],
            fromArchiveAt: archive.path,
            undo: .none,
            nameEncoding: .cp866
        )

        // No encoding declared on the way back in: the repack went through `bsdtar`, which writes
        // UTF-8 names with the zip's flag set, so the archive that needed a declaration a moment ago
        // no longer does. That this read succeeds at all is half the measurement.
        let reread = try EncryptedArchiveReader.inspect(archiveAt: archive.path)
        // Asserted through the TOC rather than on the raw entry paths, because `bsdtar` packs `.`
        // and so prefixes every member with `./` — its long-standing convention, stripped by
        // `ArchiveTOCParser`, and not what this test is about.
        #expect(ArchiveTOC(entries: reread.entries).children(inDirectory: "/").map(\.name)
            == [Self.cyrillic])
    }

    /// The other direction: the member that *cannot* be named without the declaration is the one
    /// being deleted. It is the case a wrong implementation passes by deleting nothing.
    @Test("the member that needed the declaration can itself be deleted")
    func theUnnameableMemberCanBeDeleted() throws {
        let archive = try Fixture()
        defer { archive.cleanup() }

        try ArchiveWriter.delete(
            innerPaths: ["/" + Self.cyrillic],
            fromArchiveAt: archive.path,
            undo: .none,
            nameEncoding: .cp866
        )

        let reread = try EncryptedArchiveReader.inspect(archiveAt: archive.path)
        #expect(ArchiveTOC(entries: reread.entries).children(inDirectory: "/").map(\.name)
            == ["plain.txt"])
    }

    /// **The rewrite upgrades the archive, and that is what makes a stale declaration harmless.**
    ///
    /// A declaration is stored per archive *path*, and the rewrite replaces the file at that path —
    /// so the obvious worry is that the next listing decodes the new, UTF-8 archive through the old
    /// code page and produces mojibake all over again. Measured here, it does not, and the reason is
    /// worth pinning rather than inferring: `bsdtar` sets the zip's **UTF-8 flag (general-purpose
    /// bit 11)** on the rewritten name, and `hdrcharset` applies only to entries whose flag is
    /// *clear*. So the declaration stops being consulted the moment it stops being true.
    ///
    /// That is why the store needs no `ArchiveIdentity` stamping, where the three archive *caches*
    /// all do — a stale mount answers with the wrong contents, and a stale declaration answers with
    /// nothing at all.
    @Test("the rewrite flags the name UTF-8, which makes the stale declaration inert")
    func rewriteUpgradesTheArchiveAndNeutersTheDeclaration() throws {
        let archive = try Fixture()
        defer { archive.cleanup() }

        // Keep the Cyrillic member; the ASCII one cannot show any of this, since its bytes are
        // identical under every code page and its flag is left clear either way.
        try ArchiveWriter.delete(
            innerPaths: ["/plain.txt"],
            fromArchiveAt: archive.path,
            undo: .none,
            nameEncoding: .cp866
        )

        let entry = try #require(
            try ZipCentralDirectory.entries(ofArchiveAt: archive.path)
                .first { $0.name.hasSuffix(Self.cyrillic) },
            "the rewritten archive should still hold the Cyrillic member"
        )
        #expect(entry.declaresUTF8, "\(entry.name) came back without the UTF-8 flag")

        // Both readings therefore agree, which is the property that matters at the call site.
        for declared in [ArchiveNameEncoding.cp866, nil] {
            let names = try ArchiveMounter.readTableOfContents(
                ofArchiveAt: archive.path, nameEncoding: declared
            ).children(inDirectory: "/").map(\.name)
            #expect(names == [Self.cyrillic], "read back through \(String(describing: declared))")
        }
    }

    // MARK: - What the pane draws

    /// Undeclared, the listing is readable and the bad row is not addressable — the state a user
    /// reports. `SubprocessText` is what keeps the other row visible at all.
    @Test("an undeclared archive lists with a name nobody can use")
    func undeclaredArchiveListsMojibake() throws {
        let archive = try Fixture()
        defer { archive.cleanup() }

        let toc = try ArchiveMounter.readTableOfContents(ofArchiveAt: archive.path)
        let names = toc.children(inDirectory: "/").map(\.name)
        #expect(names.contains("plain.txt"), "the readable row must survive the unreadable one")
        #expect(!names.contains(Self.cyrillic))
    }

    @Test("a declared archive lists with its real names")
    func declaredArchiveListsRealNames() throws {
        let archive = try Fixture()
        defer { archive.cleanup() }

        let toc = try ArchiveMounter.readTableOfContents(
            ofArchiveAt: archive.path, nameEncoding: .cp866
        )
        #expect(toc.children(inDirectory: "/").map(\.name).sorted()
            == ["plain.txt", Self.cyrillic])
    }

    // MARK: - Fixture

    private struct Fixture {
        let root: URL
        var path: String { root.appendingPathComponent("legacy.zip").path }

        init() throws {
            root = FileManager.default.temporaryDirectory
                .appendingPathComponent("dirnex_legacy_zip_\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            let bytes = try #require(
                Data(base64Encoded: Self.legacyCodePageZip, options: .ignoreUnknownCharacters)
            )
            try bytes.write(to: URL(fileURLWithPath: path))
        }

        func cleanup() { try? FileManager.default.removeItem(at: root) }

        private static let legacyCodePageZip = """
        UEsDBBQAAAAAAAAAIQCDFtyMAQAAAAEAAAAMAAAAj6CtruCgrKAudHh0eFBLAwQUAAAAAAAAACEA
        gxbcjAEAAAABAAAACQAAAHBsYWluLnR4dHhQSwECFAMUAAAAAAAAACEAgxbcjAEAAAABAAAADAAA
        AAAAAAAAAAAAgAEAAAAAj6CtruCgrKAudHh0UEsBAhQDFAAAAAAAAAAhAIMW3IwBAAAAAQAAAAkA
        AAAAAAAAAAAAAIABKwAAAHBsYWluLnR4dFBLBQYAAAAAAgACAHEAAABTAAAAAAA=
        """
    }
}

/// The catalog entries behind the chooser's popup.
///
/// ``DirnexCore/ArchiveNameEncoding`` carries its English as *data*, so a missing catalog entry
/// falls back to readable English rather than to a dotted key — which is the right failure and is
/// also a silent one: the popup would look perfect in an English build forever. This is the check
/// docs/NOTES.md asks for over any `allCases` enum whose labels are localized.
///
/// It asserts **presence in English**, not translation into all thirteen shipped languages. Those
/// entries do not exist yet and inventing them would be worse than the fallback; the keys are in the
/// catalog so a translator can see them, and that is the honest state to pin.
@Suite("Archive name-encoding localization")
struct ArchiveNameEncodingLocalizationTests {
    /// Read the **English** bundle by name rather than `Bundle.main`, because the app test target
    /// inherits whatever `AppleLanguages` the developer has Dirnex pinned to (docs/NOTES.md).
    @Test("every offered code page has a catalog entry")
    func everyEncodingHasACatalogEntry() throws {
        let path = try #require(Bundle.main.path(forResource: "en", ofType: "lproj"))
        let bundle = try #require(Bundle(path: path))
        for encoding in ArchiveNameEncoding.allCases {
            let value = LocalizedBundles.translation(encoding.localizationKey, in: bundle)
            #expect(value != nil, "no catalog entry for \(encoding.localizationKey)")
            #expect(value == encoding.englishName, """
            \(encoding.localizationKey): the catalog and the core disagree about the English
            """)
        }
    }
}
