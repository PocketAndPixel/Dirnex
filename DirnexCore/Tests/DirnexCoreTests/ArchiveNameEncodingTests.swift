import Foundation
import Testing

@testable import DirnexCore

/// Reading a zip whose entry names are in a code page rather than UTF-8.
///
/// The fixture is `legacy-cp866.zip`, hand-minted rather than produced by anything in this repo —
/// 218 bytes, two stored entries, one named `Панорама.txt` in **CP866** with general-purpose bit 11
/// clear, exactly as WinRAR and Explorer wrote them for years. What is under test is the *reader*,
/// so an archive built by our own writer would prove the two agree rather than that either is right.
@Suite("ArchiveNameEncoding")
struct ArchiveNameEncodingTests {
    private static let cyrillic = "Панорама.txt"

    private func legacyArchive() throws -> String {
        try EncryptedArchiveFixture.archive("legacy-cp866")
    }

    // MARK: - The vocabulary is real

    /// Every offered code page is a token **this Mac's libarchive** accepts.
    ///
    /// The defect this exists for is a typo: libarchive answers `ARCHIVE_FATAL` for a charset it
    /// does not know, which `openForReading` turns into `archiveUnreadable` — so one wrong letter
    /// in ``ArchiveNameEncoding/hdrcharset`` would ship as an archive the user simply cannot open,
    /// with nothing at build time to say why. A code page that is real but *wrong* for this
    /// archive is a different thing entirely and is allowed to answer `nil` here.
    @Test("every offered code page is one libarchive accepts")
    func everyOfferedEncodingIsAccepted() throws {
        let archive = try legacyArchive()
        for encoding in ArchiveNameEncoding.allCases {
            #expect(throws: Never.self, "\(encoding.hdrcharset) was refused by libarchive") {
                _ = try EncryptedArchiveReader.nameSamples(archiveAt: archive, encoding: encoding)
            }
        }
    }

    @Test("the offered code pages are distinct in both of their vocabularies")
    func encodingsAreDistinct() {
        let ids = Set(ArchiveNameEncoding.allCases.map(\.id))
        let tokens = Set(ArchiveNameEncoding.allCases.map(\.hdrcharset))
        #expect(ids.count == ArchiveNameEncoding.allCases.count)
        #expect(tokens.count == ArchiveNameEncoding.allCases.count)
    }

    // MARK: - Reading

    /// The measurement the whole feature rests on.
    @Test("the declared code page turns the stored bytes into the real name")
    func declaringTheCodePageReadsTheRealName() throws {
        let inspection = try EncryptedArchiveReader.inspect(
            archiveAt: try legacyArchive(), nameEncoding: .cp866
        )
        #expect(inspection.entries.map(\.archivePath) == [Self.cyrillic, "plain.txt"])
    }

    /// A *wrong* code page is silent, and that is why the user picks over a preview rather than
    /// having one inferred. Both shapes of wrongness are pinned, because a chooser needs a
    /// different answer for each: CP1251 fits these bytes and means nothing, CP1252 does not fit.
    ///
    /// **The expectation is spelled in escapes because the wrong name is invisibly wrong.** CP1251
    /// reads `a0` as U+00A0 no-break space and `ad` as U+00AD soft hyphen, so the result renders as
    /// `Џ ­®а ¬ .txt` — which compares unequal to the same thing typed with ordinary spaces, and
    /// cost this test one failure that read as a bug in the reader. The code points were taken from
    /// Python's own `cp1251` codec rather than from the value under test, so the two agreeing is
    /// evidence rather than a tautology. It is also the sharpest argument for previewing the choice:
    /// a wrong code page can produce a name that looks very nearly right.
    @Test("a wrong code page fails silently or not at all — never loudly")
    func aWrongCodePageIsNotDetectable() throws {
        let archive = try legacyArchive()
        let plausibleButWrong = "\u{40F}\u{A0}\u{AD}\u{AE}\u{430}\u{A0}\u{AC}\u{A0}.txt"

        let plausible = try EncryptedArchiveReader.nameSamples(archiveAt: archive, encoding: .cp1251)
        #expect(plausible == [plausibleButWrong], "a fitting-but-wrong code page must still answer")
        #expect(plausible != [Self.cyrillic], "and must not accidentally be the right name")

        let unmapped = try EncryptedArchiveReader.nameSamples(archiveAt: archive, encoding: .cp1252)
        #expect(unmapped == nil, "a code page with an unmapped byte must answer nil")
    }

    // MARK: - The table of contents built from those headers

    /// The pane's own view of a legacy archive, once the code page is declared: the same tree it
    /// would get from `bsdtar`, with names somebody can read.
    @Test("a declared archive lists through libarchive with its real names")
    func declaredArchiveListsWithRealNames() throws {
        let inspection = try EncryptedArchiveReader.inspect(
            archiveAt: try legacyArchive(), nameEncoding: .cp866
        )
        let toc = ArchiveTOC(entries: inspection.entries)
        #expect(toc.children(inDirectory: "/").map(\.name).sorted() == ["plain.txt", Self.cyrillic])
    }

    /// The entries route must synthesize the ancestors an archive omits, exactly as the text one
    /// does — otherwise a declared archive's deep folders become unwalkable, which reads as the
    /// declaration having broken the archive.
    @Test("the entries route synthesizes ancestors the archive omitted")
    func entriesRouteSynthesizesAncestors() throws {
        let inspection = try EncryptedArchiveReader.inspect(
            archiveAt: try EncryptedArchiveFixture.archive("plain-bsdtar")
        )
        let toc = ArchiveTOC(entries: inspection.entries)
        #expect(toc.isDirectory(atInnerPath: "/notes"))
        #expect(toc.isDirectory(atInnerPath: "/notes/nested"))
        #expect(toc.children(inDirectory: "/notes/nested").map(\.name) == ["deep.txt"])
    }

    /// A symlink has to survive the crossing, since the tree draws it and F5 recreates it.
    @Test("the entries route carries a symlink and its target")
    func entriesRouteCarriesSymlinks() throws {
        let inspection = try EncryptedArchiveReader.inspect(
            archiveAt: try EncryptedArchiveFixture.archive("plain-bsdtar")
        )
        let toc = ArchiveTOC(entries: inspection.entries)
        let link = try #require(toc.children(inDirectory: "/").first { $0.name == "link.txt" })
        #expect(link.kind == .symlink)
        #expect(link.symlinkDestination == "notes/hello.txt")
    }

    // MARK: - Detection, and the unchanged default

    /// Asked with no encoding, the sampler is the detector — which is what saves the app a probe.
    @Test("no declared encoding answers nil for an archive whose names are not UTF-8")
    func undeclaredLegacyArchiveIsDetected() throws {
        let samples = try EncryptedArchiveReader.nameSamples(
            archiveAt: try legacyArchive(), encoding: nil
        )
        #expect(samples == nil)
    }

    /// The narrowness control for the detector: a UTF-8 archive must *not* be reported as needing a
    /// declaration, or the app offers the choice over every archive anybody opens.
    @Test("a UTF-8 archive needs no declaration")
    func utf8ArchiveNeedsNoDeclaration() throws {
        let samples = try EncryptedArchiveReader.nameSamples(
            archiveAt: try EncryptedArchiveFixture.archive("plain-bsdtar"), encoding: nil
        )
        #expect(samples != nil, "an archive whose names are UTF-8 must not read as undeclarable")
    }

    /// Only non-ASCII names are sampled: an ASCII one reads identically under every candidate, so
    /// previewing it would ask somebody to choose between twenty identical rows.
    @Test("only names that differ between code pages are sampled")
    func onlyNonASCIINamesAreSampled() throws {
        let samples = try EncryptedArchiveReader.nameSamples(
            archiveAt: try legacyArchive(), encoding: .cp866
        )
        #expect(samples == [Self.cyrillic], "plain.txt must not be offered as a preview")
    }

    @Test("the sample count is bounded by the limit asked for")
    func samplingStopsAtTheLimit() throws {
        let samples = try EncryptedArchiveReader.nameSamples(
            archiveAt: try legacyArchive(), encoding: .cp866, limit: 0
        )
        #expect(samples == [])
    }

    /// Nothing above may have changed what an *undeclared* read does — that path is what every
    /// existing caller still takes, and its refusal is the one the rewrite rests on.
    @Test("an undeclared legacy archive still refuses to be inspected")
    func undeclaredInspectionStillRefuses() throws {
        #expect(throws: EncryptedArchiveError.self) {
            _ = try EncryptedArchiveReader.inspect(archiveAt: try legacyArchive())
        }
    }

    @Test("a UTF-8 archive still inspects with no encoding declared")
    func utf8ArchiveStillInspects() throws {
        let inspection = try EncryptedArchiveReader.inspect(
            archiveAt: try EncryptedArchiveFixture.archive("plain-bsdtar")
        )
        #expect(!inspection.entries.isEmpty)
    }
}
