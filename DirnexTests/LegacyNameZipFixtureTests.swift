import DirnexCore
import Foundation
import Testing

@testable import Dirnex

/// That ``LegacyNameZip`` mints what it says it does — a fixture's own control, and the reason
/// anything built on it is evidence (PLAN.md §M27).
///
/// A builder that quietly failed to patch would produce a perfectly ordinary UTF-8 archive, and
/// every suite resting on it would pass while measuring nothing at all. That is the shape
/// docs/NOTES.md keeps warning about: a control that fires nowhere reads as the rule being
/// redundant. So the finished bytes are read by an **independent** reader — `ZipCentralDirectory`,
/// hand-written and knowing nothing about libarchive — and compared against the properties the
/// 218-byte hand-minted blob the other suites carry is already known to have.
@Suite("Legacy code-page zip fixture")
struct LegacyNameZipFixtureTests {
    private static let cyrillic = "Панорама.txt"
    /// `Панорама.txt` in CP866. Written out rather than computed, so a builder that encoded through
    /// the wrong code page could not agree with its own test.
    private static let cyrillicCP866 = Data([
        0x8F, 0xA0, 0xAD, 0xAE, 0xE0, 0xA0, 0xAC, 0xA0, 0x2E, 0x74, 0x78, 0x74
    ])

    private struct Fixture {
        let root: URL
        let path: String

        init(
            _ members: [LegacyNameZip.Member],
            encryption: ArchiveEncryption = .none,
            passphrase: ArchivePassphrase? = nil
        ) throws {
            root = FileManager.default.temporaryDirectory
                .appendingPathComponent("legacy_fixture_control_\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            path = root.appendingPathComponent("legacy.zip").path
            try LegacyNameZip.write(
                members, to: path, encryption: encryption, passphrase: passphrase
            )
        }

        func cleanup() { try? FileManager.default.removeItem(at: root) }
    }

    /// The bytes on disk, judged by a reader that shares nothing with the builder.
    @Test("the name is stored as its CP866 bytes with the UTF-8 flag clear")
    func storesCodePageBytesWithTheFlagClear() throws {
        let fixture = try Fixture([
            .text(Self.cyrillic, "x"), .text("plain.txt", "x")
        ])
        defer { fixture.cleanup() }

        let entries = try ZipCentralDirectory.entries(ofArchiveAt: fixture.path)
        #expect(entries.count == 2)
        let legacy = try #require(entries.first { $0.rawName == Self.cyrillicCP866 })
        #expect(!legacy.declaresUTF8, "the placeholder's UTF-8 flag survived the patch")
        // And the ASCII member is untouched by any of it — the row a user can still read.
        let plain = try #require(entries.first { $0.name == "plain.txt" })
        #expect(plain.rawName == Data("plain.txt".utf8))
    }

    /// The same three answers the hand-minted blob gives, which is what makes this builder a
    /// stand-in for it: undeclared it is not readable at all, CP866 reads the name somebody typed,
    /// CP1251 reads well-formed nonsense, and CP1252 does not fit.
    ///
    /// The CP1251 reading is the one worth spelling out. Its separators are **U+00A0 no-break
    /// space** and **U+00AD soft hyphen**, so it compares unequal to the same thing typed with
    /// ordinary spaces — which cost a test failure that read as a bug in the reader
    /// (docs/NOTES.md ▸ bsdtar). The expectation is taken from an independent decoder rather than
    /// from ours.
    @Test("it reads exactly as the hand-minted fixture does, under every candidate")
    func readsLikeTheHandMintedFixture() throws {
        let fixture = try Fixture([
            .text(Self.cyrillic, "x"), .text("plain.txt", "x")
        ])
        defer { fixture.cleanup() }

        let undeclared = try EncryptedArchiveReader.nameSamples(
            archiveAt: fixture.path, encoding: nil
        )
        let asCP866 = try EncryptedArchiveReader.nameSamples(
            archiveAt: fixture.path, encoding: .cp866
        )
        let asCP1251 = try EncryptedArchiveReader.nameSamples(
            archiveAt: fixture.path, encoding: .cp1251
        )
        let asCP1252 = try EncryptedArchiveReader.nameSamples(
            archiveAt: fixture.path, encoding: .cp1252
        )
        #expect(undeclared == nil, "an undeclared legacy archive must not answer a name")
        #expect(asCP866 == [Self.cyrillic])
        #expect(
            asCP1251 == ["\u{40F}\u{A0}\u{AD}\u{AE}\u{430}\u{A0}\u{AC}\u{A0}.txt"],
            "a fitting-but-wrong code page must still answer, and answer nonsense"
        )
        #expect(asCP1252 == nil, "a code page with an unmapped byte must answer nil")
    }

    /// And the pane's own route agrees: undeclared it lists the readable row and loses the other,
    /// declared it lists both. This is the state a user reports, reproduced by the builder.
    @Test("the listing loses the unreadable row undeclared and holds it declared")
    func listingMatchesTheReportedState() throws {
        let fixture = try Fixture([
            .text(Self.cyrillic, "x"), .text("plain.txt", "x")
        ])
        defer { fixture.cleanup() }

        let undeclared = try ArchiveMounter.readTableOfContents(ofArchiveAt: fixture.path)
        #expect(undeclared.hasUnreadableNames)
        #expect(undeclared.children(inDirectory: "/").map(\.name).contains("plain.txt"))
        #expect(!undeclared.children(inDirectory: "/").map(\.name).contains(Self.cyrillic))

        let declared = try ArchiveMounter.readTableOfContents(
            ofArchiveAt: fixture.path, nameEncoding: .cp866
        )
        #expect(declared.children(inDirectory: "/").map(\.name).sorted()
            == ["plain.txt", Self.cyrillic])
    }

    /// The builder refuses rather than shipping a fixture that is not legacy at all — the failure
    /// this whole suite exists to make impossible.
    @Test("a name with no CP866 spelling is refused rather than silently stored as UTF-8")
    func refusesANameItCannotEncode() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("legacy_fixture_refusal_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        #expect(throws: LegacyNameZip.FixtureError.self) {
            // Japanese has no CP866 spelling, so there is nothing to patch in.
            try LegacyNameZip.write(
                [.text("日本語.txt", "x")],
                to: root.appendingPathComponent("bad.zip").path
            )
        }
    }
}
