import DirnexCore
import Foundation
import Testing

@testable import Dirnex

/// Extracting the one row a hidden-names archive lists (PLAN.md §M4 nested archives × §M19
/// encryption).
///
/// An archive packed with "Hide file names" carries a single entry, `Contents.tar`, and that entry
/// is what the pane draws — so Enter, F5, ⌘Y and F4 all ask for it by name. `EncryptedArchiveReader`
/// undoes the wrap transparently, which is right for every caller that wants the *files* and leaves
/// the one asking for the *container* holding a path that was never written. Entering it therefore
/// mounted a file that did not exist, and `bsdtar -tvf`'s failure surfaced as "Couldn't read the
/// archive “Contents.tar”" — a claim about the archive where the truth was about the extraction.
///
/// The assertions go through `ArchiveMounter`, not through a `fileExists` check, because that is the
/// step that actually failed: a file on disk that the mounter cannot read would pass the cheaper
/// check and reproduce the bug.
@Suite("Extracting a hidden-names wrapper")
struct ArchiveExtractorWrapperTests {
    private static let passphrase = ArchivePassphrase("correct horse")

    // MARK: - The reported bug

    @Test("the wrapper extracts to a file the mounter can actually read")
    func wrapperIsMountable() throws {
        let fixture = try Fixture(namePrivacy: .hidden)
        defer { fixture.remove() }

        let extraction = try ArchiveExtractor.extract(
            innerPaths: ["/Contents.tar"],
            fromArchiveAt: fixture.archive,
            passphrase: Self.passphrase
        )
        defer { try? FileManager.default.removeItem(at: extraction.directory) }

        let toc = try ArchiveMounter.readTableOfContents(ofArchiveAt: extraction.extractedPaths[0])
        #expect(toc.children(inDirectory: "/").map(\.name) == ["payload"])
        #expect(toc.children(inDirectory: "/payload").map(\.name).sorted() == ["one.txt", "two.txt"])
    }

    // MARK: - The rule stays narrow

    @Test("asking for anything else still gets the payload, unwrapped")
    func nonWrapperRequestStillUnwraps() throws {
        let fixture = try Fixture(namePrivacy: .hidden)
        defer { fixture.remove() }

        let extraction = try ArchiveExtractor.extract(
            innerPaths: ["/payload/one.txt"],
            fromArchiveAt: fixture.archive,
            passphrase: Self.passphrase
        )
        defer { try? FileManager.default.removeItem(at: extraction.directory) }

        #expect(try String(contentsOfFile: extraction.extractedPaths[0], encoding: .utf8) == "first")
        // The container must not be left beside the files it carried — the unwrap still happened.
        let wrapper = extraction.directory.appendingPathComponent("Contents.tar").path
        #expect(!FileManager.default.fileExists(atPath: wrapper))
    }

    @Test("an ordinary encrypted archive extracts its member unchanged")
    func visibleNamesAreUntouched() throws {
        let fixture = try Fixture(namePrivacy: .visible)
        defer { fixture.remove() }

        let extraction = try ArchiveExtractor.extract(
            innerPaths: ["/payload/two.txt"],
            fromArchiveAt: fixture.archive,
            passphrase: Self.passphrase
        )
        defer { try? FileManager.default.removeItem(at: extraction.directory) }

        #expect(
            try String(contentsOfFile: extraction.extractedPaths[0], encoding: .utf8) == "second"
        )
    }

    // MARK: - The guard that turned this into a wrong error

    @Test("a member that never landed throws instead of reporting a path that isn't there")
    func nothingLandedThrows() throws {
        let fixture = try Fixture(namePrivacy: .visible)
        defer { fixture.remove() }

        // The encrypted route places what the archive holds and nothing else; this member is not in
        // it. Before the guard covered that route, the caller was handed its nominal location and
        // discovered the miss by trying to use the file.
        #expect(throws: VFSError.unsupported(.archiveExtractFailed(archive: "fixture.zip"))) {
            try ArchiveExtractor.extract(
                innerPaths: ["/payload/absent.txt"],
                fromArchiveAt: fixture.archive,
                passphrase: Self.passphrase
            )
        }
    }

    /// A real AES-256 archive on disk, written by the app's own writer so what is extracted is
    /// exactly the shape Dirnex produces.
    ///
    /// It writes into its own directory rather than into the shared temp root: the writer puts its
    /// `.dirnex-pack-` temporary beside the destination, and the hidden-names path opens a second
    /// one for the inner tar, so packing into the shared root strews temporaries through every
    /// other archive suite's view of its own siblings.
    private struct Fixture {
        let directory: URL
        let archive: String

        func remove() { try? FileManager.default.removeItem(at: directory) }

        init(namePrivacy: ArchiveNamePrivacy) throws {
            directory = FileManager.default.temporaryDirectory
                .appendingPathComponent("ArchiveExtractorWrapper-\(UUID().uuidString)")
            let source = directory.appendingPathComponent("source", isDirectory: true)
            let payload = source.appendingPathComponent("payload", isDirectory: true)
            try FileManager.default.createDirectory(at: payload, withIntermediateDirectories: true)
            try "first".write(
                to: payload.appendingPathComponent("one.txt"), atomically: true, encoding: .utf8
            )
            try "second".write(
                to: payload.appendingPathComponent("two.txt"), atomically: true, encoding: .utf8
            )

            archive = directory.appendingPathComponent("fixture.zip").path
            try EncryptedArchiveWriter.write(
                items: try ArchiveSourceEnumerator.items(
                    inDirectory: source.path, names: ["payload"]
                ),
                toArchiveAt: archive,
                encryption: .aes256,
                passphrase: ArchiveExtractorWrapperTests.passphrase,
                namePrivacy: namePrivacy
            )
        }
    }
}
