import DirnexCore
import Foundation
import Testing

@testable import Dirnex

/// An archive that is **encrypted *and* legacy** — the composition PLAN.md §M27 listed as threaded
/// and never run, because no fixture in this repo could be both.
///
/// The passphrase and the code page are independent facts about the same file and the reader takes
/// them as two options on one open, so "they compose by construction" was a fair reading of the
/// code. Running it found the place where they do not: the *routing* in front of the reader asks
/// whether the archive is encrypted by inspecting it, and inspecting a legacy archive throws on the
/// first name — so the answer came back **"not encrypted"** for an archive that is, and the
/// extraction went to `bsdtar`. Measured 2026-09-09, `bsdtar` then wrote an 8-byte file of **zeros**
/// under the right name, after six seconds and 170 KB of `Enter passphrase:` nobody can answer, and
/// the guard that asks whether anything landed saw a file and reported success.
///
/// So the encryption question had to stop depending on the names
/// (``DirnexCore/EncryptedArchiveReader/holdsEncryptedEntries(archiveAt:)``), and these are what say
/// it does.
@Suite("An archive that is encrypted and legacy")
struct ArchiveNameEncodingEncryptedTests {
    private static let cyrillic = "Панорама.txt"
    private static let passphrase = ArchivePassphrase("correct horse")

    /// An AES-256 zip whose Cyrillic member's name is stored as CP866 bytes with the UTF-8 flag
    /// clear, beside a readable ASCII member. `plain.txt` is the one that matters most: it is the
    /// row a user *can* see, and it is the row `bsdtar` was filling with zeros.
    private struct Fixture {
        let root: URL
        let path: String

        init(encryption: ArchiveEncryption = .aes256, legacy: Bool = true) throws {
            root = FileManager.default.temporaryDirectory
                .appendingPathComponent("legacy_encrypted_\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            path = root.appendingPathComponent("archive.zip").path
            try LegacyNameZip.write(
                [
                    .text(legacy ? cyrillic : "readable.txt", "secret contents"),
                    .text("plain.txt", "readable contents")
                ],
                to: path,
                encryption: encryption,
                passphrase: encryption.isEncrypted ? passphrase : nil
            )
        }

        func cleanup() { try? FileManager.default.removeItem(at: root) }
    }

    /// The fixture's own precondition, asserted rather than assumed: it really is both things at
    /// once. Without this every assertion below could be true of an archive that is merely one.
    @Test("the fixture is encrypted and its names are not UTF-8")
    func fixtureIsBothThings() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }

        let entries = try ZipCentralDirectory.entries(ofArchiveAt: fixture.path)
        // Hoisted: a key-path `allSatisfy` cannot sit inside `#expect` (docs/NOTES.md ▸ Testing).
        let everyEntryEncrypted = entries.allSatisfy(\.isEncrypted)
        #expect(everyEntryEncrypted, "every member's data should be encrypted")
        #expect(
            entries.contains { !$0.declaresUTF8 && $0.name == "<undecodable>" },
            "no member's name is stored in a code page"
        )
    }

    // MARK: - The chooser, before anyone has typed anything

    /// **The offer costs no passphrase, and that is a property rather than an accident.** A zip's
    /// central directory is never encrypted, so the names can be previewed under every candidate
    /// before the user has typed a word — which is what lets the code page be settled first and the
    /// passphrase asked once, rather than the other way round.
    @Test("the code page can be chosen without the passphrase")
    func theChooserNeedsNoPassphrase() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }

        let undeclared = try EncryptedArchiveReader.nameSamples(
            archiveAt: fixture.path, encoding: nil
        )
        let asCP866 = try EncryptedArchiveReader.nameSamples(
            archiveAt: fixture.path, encoding: .cp866
        )
        let asCP1252 = try EncryptedArchiveReader.nameSamples(
            archiveAt: fixture.path, encoding: .cp1252
        )
        #expect(undeclared == nil, "an undeclared legacy archive must not answer a name")
        #expect(asCP866 == [Self.cyrillic])
        #expect(asCP1252 == nil, "a code page that does not fit must still be refused")
    }

    /// And the listing agrees, through the pane's own route.
    @Test("declared, it lists both names; undeclared, it loses the one it cannot read")
    func theListingComposes() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }

        let undeclared = try ArchiveMounter.readTableOfContents(ofArchiveAt: fixture.path)
        #expect(undeclared.hasUnreadableNames)

        let declared = try ArchiveMounter.readTableOfContents(
            ofArchiveAt: fixture.path, nameEncoding: .cp866
        )
        #expect(declared.children(inDirectory: "/").map(\.name).sorted()
            == ["plain.txt", Self.cyrillic])
    }

    // MARK: - The encryption question

    /// **The bug, pinned.** `withArchivePassphrase` and the extractor's own routing both rest on
    /// this one answer, and it used to be derived from an inspection that a legacy archive makes
    /// throw — so it said *no* for an archive that is encrypted, no passphrase was ever asked for,
    /// and the extraction fell through to `bsdtar`.
    ///
    /// Asked with no code page on purpose: that is the state every gesture is in before the chooser
    /// has been answered, and it is the only state in which the old answer was wrong.
    @Test("an undeclared legacy archive still reports that it is encrypted")
    func encryptionIsAnsweredWithoutTheNames() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }

        #expect(ArchiveExtractor.needsPassphrase(forArchiveAt: fixture.path))
        // The primitive underneath, asked directly — it must not need the names either.
        let encrypted = try EncryptedArchiveReader.holdsEncryptedEntries(archiveAt: fixture.path)
        #expect(encrypted)
    }

    /// The narrowness control, and without it "report encrypted" would pass implemented as "always
    /// say yes" — which would put a passphrase prompt in front of every ordinary archive.
    @Test("a legacy archive that is not encrypted still reports that it is not")
    func anUnencryptedLegacyArchiveIsNotClaimedEncrypted() throws {
        let fixture = try Fixture(encryption: .none)
        defer { fixture.cleanup() }

        #expect(!ArchiveExtractor.needsPassphrase(forArchiveAt: fixture.path))
        let encrypted = try EncryptedArchiveReader.holdsEncryptedEntries(archiveAt: fixture.path)
        #expect(!encrypted)
        // The precondition: it really is the legacy shape, so what is being measured is the
        // encryption answer and not a fixture that failed to be legacy.
        let toc = try ArchiveMounter.readTableOfContents(ofArchiveAt: fixture.path)
        #expect(toc.hasUnreadableNames)
    }

    /// The other narrowness control, and the one that guards the *change*: `needsPassphrase` now
    /// answers for every archive through a different primitive, so an ordinary encrypted one — UTF-8
    /// names, nothing declared, nothing to declare — has to behave exactly as it always did.
    @Test("an ordinary encrypted archive is unaffected by any of this")
    func anOrdinaryEncryptedArchiveIsUnchanged() throws {
        let fixture = try Fixture(legacy: false)
        defer { fixture.cleanup() }

        #expect(ArchiveExtractor.needsPassphrase(forArchiveAt: fixture.path))
        // Its names need no declaration at all, which is what makes it the control.
        let samples = try EncryptedArchiveReader.nameSamples(
            archiveAt: fixture.path, encoding: nil
        )
        #expect(samples != nil, "an ASCII-named archive must not read as legacy")

        let extraction = try ArchiveExtractor.extract(
            innerPaths: ["/readable.txt"],
            fromArchiveAt: fixture.path,
            passphrase: Self.passphrase
        )
        defer { try? FileManager.default.removeItem(at: extraction.directory) }
        let contents = try String(contentsOfFile: extraction.extractedPaths[0], encoding: .utf8)
        #expect(contents == "secret contents")
    }

    // MARK: - Extraction

    /// The whole composition, through the app's own extractor: the declaration reaches the reader,
    /// the passphrase reaches the same open, and both members land under the names somebody typed
    /// with the bytes they were packed with.
    @Test("declared and unlocked, both members extract with their real names and bytes")
    func extractionComposesBothFacts() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }

        let extraction = try ArchiveExtractor.extract(
            innerPaths: ["/" + Self.cyrillic, "/plain.txt"],
            fromArchiveAt: fixture.path,
            passphrase: Self.passphrase,
            nameEncoding: .cp866
        )
        defer { try? FileManager.default.removeItem(at: extraction.directory) }

        let contents = extraction.extractedPaths.map {
            (
                ($0 as NSString).lastPathComponent,
                (try? String(contentsOfFile: $0, encoding: .utf8)) ?? "<unreadable>"
            )
        }
        #expect(
            contents.contains { $0 == (Self.cyrillic, "secret contents") },
            "extracted \(contents)"
        )
        // The row `bsdtar` was filling with zeros. Its *bytes* are the assertion, not its
        // existence — a file of the right size and the wrong contents is what the old path made.
        #expect(
            contents.contains { $0 == ("plain.txt", "readable contents") },
            "extracted \(contents)"
        )
    }

    /// Undeclared, nothing is guessed and nothing is written: the extraction refuses for the
    /// **name** reason, which is what puts the chooser in front of the user.
    ///
    /// This is the assertion the old routing could not satisfy in either direction — it neither
    /// refused nor extracted, it produced zeros and called them a success.
    @Test("undeclared, it refuses for the name and places nothing")
    func undeclaredExtractionRefusesRatherThanGuessing() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }

        var thrown: Error?
        do {
            _ = try ArchiveExtractor.extract(
                innerPaths: ["/plain.txt"],
                fromArchiveAt: fixture.path,
                passphrase: Self.passphrase
            )
        } catch { thrown = error }

        let refusal = try #require(thrown)
        // Asserted through the app's own predicate, since what the refusal has to *do* is offer the
        // chooser — a different error of the right shape would report "couldn't extract" instead.
        #expect(
            PanelViewController.isNameEncodingRefusal(refusal),
            "refused with \(refusal)"
        )
    }

    /// And the passphrase is still checked on its own terms, which is what says the two facts are
    /// composed rather than one masking the other: with the code page right and the passphrase
    /// wrong, the failure names the passphrase.
    @Test("a wrong passphrase is reported as a wrong passphrase, not as a name")
    func theTwoRefusalsStaySeparate() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }

        var thrown: Error?
        do {
            _ = try ArchiveExtractor.extract(
                innerPaths: ["/plain.txt"],
                fromArchiveAt: fixture.path,
                passphrase: ArchivePassphrase("wrong"),
                nameEncoding: .cp866
            )
        } catch { thrown = error }

        #expect(
            thrown as? EncryptedArchiveError == .incorrectPassphrase,
            "refused with \(String(describing: thrown))"
        )
    }

    /// The other half of the same claim: declared, but with no passphrase at all.
    @Test("declared with no passphrase, it asks for the passphrase")
    func aDeclaredArchiveStillNeedsItsPassphrase() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }

        var thrown: Error?
        do {
            _ = try ArchiveExtractor.extract(
                innerPaths: ["/plain.txt"],
                fromArchiveAt: fixture.path,
                nameEncoding: .cp866
            )
        } catch { thrown = error }

        #expect(
            thrown as? EncryptedArchiveError == .passphraseRequired,
            "refused with \(String(describing: thrown))"
        )
    }

    // MARK: - The rewrite

    /// The rewrite composes too, and it is the gesture with the most to lose: an archive that comes
    /// back unencrypted, or under mojibake names, is a file somebody cannot open any more.
    @Test("a declared, unlocked archive rewrites, staying encrypted and keeping its names")
    func theRewriteComposesBothFacts() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }

        try ArchiveWriter.delete(
            innerPaths: ["/plain.txt"],
            fromArchiveAt: fixture.path,
            passphrase: Self.passphrase,
            undo: .none,
            nameEncoding: .cp866
        )

        // Still encrypted — the property a repack through the wrong engine would silently drop.
        let entries = try ZipCentralDirectory.entries(ofArchiveAt: fixture.path)
        let stillEncrypted = entries.allSatisfy(\.isEncrypted)
        #expect(stillEncrypted, "the rewrite dropped the encryption")

        // And the surviving member is the one that needed the declaration, readable now with no
        // declaration at all — the same upgrade the unencrypted rewrite makes.
        let reread = try EncryptedArchiveReader.inspect(archiveAt: fixture.path)
        #expect(ArchiveTOC(entries: reread.entries).children(inDirectory: "/").map(\.name)
            == [Self.cyrillic])
    }
}
