import Foundation
import Testing

@testable import Dirnex
@testable import DirnexCore

/// Which container a fixture is. Both hold the same two members — one named `Панорама.txt` in
/// **CP866** and an ASCII `plain.txt` — and differ only in the thing under test: a zip records a
/// UTF-8 *flag* and leaves it clear, while a tar records nothing about its names at all, which is
/// why the two arrive at the reader in the same state by different routes.
private enum LegacyArchive {
    case zip, tarGz

    var fileName: String {
        switch self {
        case .zip: "legacy.zip"
        case .tarGz: "legacy.tar.gz"
        }
    }

    /// 218 bytes for the zip: two stored entries, `Панорама.txt` in CP866 with general-purpose bit
    /// 11 clear, as Windows tools wrote them for years. 135 for the tar, whose name field carries
    /// the same bytes with no flag to clear — both verified by listing them under the app's own
    /// pinned locale, which escapes some of those bytes and passes the rest through.
    var base64: String {
        switch self {
        case .zip: """
            UEsDBBQAAAAAAAAAIQCDFtyMAQAAAAEAAAAMAAAAj6CtruCgrKAudHh0eFBLAwQUAAAAAAAAACEA
            gxbcjAEAAAABAAAACQAAAHBsYWluLnR4dHhQSwECFAMUAAAAAAAAACEAgxbcjAEAAAABAAAADAAA
            AAAAAAAAAAAAgAEAAAAAj6CtruCgrKAudHh0UEsBAhQDFAAAAAAAAAAhAIMW3IwBAAAAAQAAAAkA
            AAAAAAAAAAAAAIABKwAAAHBsYWluLnR4dFBLBQYAAAAAAgACAHEAAABTAAAAAAA=
            """
        case .tarGz: """
            H4sIAAAAAAAC/+3Tyw1AQBRG4VuKCmQejHosJSLCSKhCC1MAalKKiaWlhEScb/Mnd3U3Zw7rtocl
            pH708hAVuSw7N7pupEUZ42xu7HnX2lotiZIXDL0vu/iK/NMo+LO2Lqvmyfjv9K8KZwr6f8NEAgAA
            AAAAAAAAAAAAAJ92AIY8vU8AKAAA
            """
        }
    }
}

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

    // MARK: - A container that is not a zip

    /// **A `.tar.gz` behaves the same way, and until now that was a hope rather than a
    /// measurement** (PLAN.md §M27 listed it as threaded and never run).
    ///
    /// It was zip that made the reported case, because only zip has a charset *flag* to get wrong —
    /// a tar simply stores the bytes it was given and says nothing about them, which is the same
    /// state a zip with bit 11 clear is in. Measured 2026-09-09, the whole chain is identical: the
    /// undeclared listing loses the name to `vis(3)` and the decoder in exactly the shape the zip
    /// does, the declaration reads it back, and the rewrite keeps it.
    ///
    /// The **container** is the half worth asserting past that. `ArchiveMutation
    /// .repackAllArguments` infers the format from the new archive's suffix, so a gzip'd tar has to
    /// come back a gzip'd tar rather than the zip the other tests happen to produce — which is what
    /// keeps a rewrite from silently changing the kind of file somebody has.
    @Test("a legacy .tar.gz reads, rewrites and stays a gzip'd tar")
    func legacyTarGzIsReadableAndKeepsItsContainer() throws {
        let archive = try Fixture(kind: .tarGz)
        defer { archive.cleanup() }

        // Undeclared, the row is unusable — the same state the zip fixture is in.
        let raw = try ArchiveMounter.readTableOfContents(ofArchiveAt: archive.path)
        #expect(raw.hasUnreadableNames)
        #expect(!raw.children(inDirectory: "/").map(\.name).contains(Self.cyrillic))

        // Declared, `hdrcharset` reads it — so the option is not a zip-only lever.
        let declared = try ArchiveMounter.readTableOfContents(
            ofArchiveAt: archive.path, nameEncoding: .cp866
        )
        #expect(declared.children(inDirectory: "/").map(\.name).sorted()
            == ["plain.txt", Self.cyrillic])

        try ArchiveWriter.delete(
            innerPaths: ["/plain.txt"],
            fromArchiveAt: archive.path,
            undo: .none,
            nameEncoding: .cp866
        )

        // Still gzip, byte one and two — the suffix is what the repack infers from, so a rewrite
        // that fell back to zip would be invisible in every assertion about the *members*.
        let bytes = try Data(contentsOf: URL(fileURLWithPath: archive.path))
        #expect(bytes.prefix(2) == Data([0x1f, 0x8b]), "no longer a gzip stream")

        // And the name survives — read back with nothing declared, since a tar stores the raw
        // UTF-8 bytes the extracted tree carried and needs no flag to be readable.
        let reread = try ArchiveMounter.readTableOfContents(ofArchiveAt: archive.path)
        #expect(reread.children(inDirectory: "/").map(\.name) == [Self.cyrillic])
        #expect(!reread.hasUnreadableNames)
    }

    // MARK: - Fixture

    private struct Fixture {
        let root: URL
        let path: String

        init(kind: LegacyArchive = .zip) throws {
            root = FileManager.default.temporaryDirectory
                .appendingPathComponent("dirnex_legacy_archive_\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            path = root.appendingPathComponent(kind.fileName).path
            let bytes = try #require(
                Data(base64Encoded: kind.base64, options: .ignoreUnknownCharacters)
            )
            try bytes.write(to: URL(fileURLWithPath: path))
        }

        func cleanup() { try? FileManager.default.removeItem(at: root) }
    }
}

/// The catalog entries behind the chooser's popup.
///
/// ``DirnexCore/ArchiveNameEncoding`` carries its English as *data*, so a missing catalog entry
/// falls back to readable English rather than to a dotted key — which is the right failure and is
/// also a silent one: the popup would look perfect in an English build forever. This is the check
/// docs/NOTES.md asks for over any `allCases` enum whose labels are localized.
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

    /// And it is translated everywhere, which the test above deliberately did not demand while the
    /// thirteen translations were still outstanding (PLAN.md §M27).
    ///
    /// The still-English half is what makes this more than a presence check: an entry copied in and
    /// left alone renders perfectly and reads as a translation nobody wrote. It can be demanded of
    /// every one of these, unlike a command title, because the **script name** is the part that
    /// carries the meaning and no shipped language spells "Cyrillic" or "Japanese" the English way
    /// — only the platform and the code-page token stay put, and neither is a whole label.
    @Test("every offered code page is translated in every shipped language")
    func everyEncodingIsTranslated() throws {
        for language in LocalizedBundles.translated {
            let bundle = try LocalizedBundles.bundle(for: language)
            for encoding in ArchiveNameEncoding.allCases {
                let key = encoding.localizationKey
                let value = LocalizedBundles.translation(key, in: bundle)
                #expect(value != nil, "\(language.code): no \(key)")
                if let value {
                    #expect(
                        value != encoding.englishName,
                        "\(language.code): \(key) is still English"
                    )
                }
            }
        }
    }
}
