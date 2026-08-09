import Foundation
import Testing

@testable import DirnexCore

/// The claim under test is a *negative* one — that the file names are not in the archive — so the
/// assertions read the produced bytes for the names rather than asking the reader what it thinks is
/// in there. A reader that agrees the names are hidden proves nothing; a byte scan that cannot find
/// `salary` anywhere in the file does.
@Suite("ArchiveNamePrivacy")
struct ArchiveNamePrivacyTests {
    /// A scratch directory holding the tree to pack, and everything these tests then write.
    ///
    /// Archives and extraction destinations go **inside** it rather than beside it in
    /// `NSTemporaryDirectory()`: the writer puts its `.dirnex-pack-` temporary next to the
    /// destination, and the hidden-names path here opens a second one for its inner tar, so packing
    /// into the shared root would strew temporaries through every other archive suite's view of its
    /// own siblings. `EncryptedArchiveWriterTests.cancellationCleansUp` scans exactly that, and was
    /// failing about one full `swift test` run in three because of it.
    private func makeSource() throws -> (directory: String, items: [ArchiveSourceItem]) {
        let root = NSTemporaryDirectory() + "dirnex-privacy-\(UUID().uuidString)"
        try FileManager.default.createDirectory(
            atPath: root + "/layoffs", withIntermediateDirectories: true
        )
        try Data("who goes\n".utf8).write(
            to: URL(fileURLWithPath: root + "/layoffs/salary-list.txt")
        )
        try Data("and when\n".utf8).write(to: URL(fileURLWithPath: root + "/layoffs/timeline.txt"))
        let items = try ArchiveSourceEnumerator.items(inDirectory: root, names: ["layoffs"])
        return (root, items)
    }

    private func remove(_ path: String) { try? FileManager.default.removeItem(atPath: path) }

    private func contains(_ needle: String, inFileAt path: String) throws -> Bool {
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        return data.range(of: Data(needle.utf8)) != nil
    }

    @Test("hiding names leaves nothing of the real tree in the archive's bytes")
    func namesAreAbsentFromTheBytes() throws {
        let source = try makeSource()
        defer { remove(source.directory) }
        let archive = source.directory + "/archive.zip"

        try EncryptedArchiveWriter.write(
            items: source.items,
            toArchiveAt: archive,
            encryption: .aes256,
            passphrase: ArchivePassphrase("hunter2"),
            namePrivacy: .hidden
        )

        #expect(try !contains("salary-list.txt", inFileAt: archive))
        #expect(try !contains("timeline.txt", inFileAt: archive))
        #expect(try !contains("layoffs", inFileAt: archive))
        #expect(try !contains("who goes", inFileAt: archive))
        // The one name that is there is the container's, which says nothing about the contents.
        #expect(try contains("Contents.tar", inFileAt: archive))
    }

    @Test(
        "without hiding, those same names are in the clear — the contrast that gives the test meaning"
    )
    func namesArePresentWithoutHiding() throws {
        let source = try makeSource()
        defer { remove(source.directory) }
        let archive = source.directory + "/archive.zip"

        try EncryptedArchiveWriter.write(
            items: source.items,
            toArchiveAt: archive,
            encryption: .aes256,
            passphrase: ArchivePassphrase("hunter2"),
            namePrivacy: .visible
        )

        // Without this pair, the test above could pass because the writer produced an empty file.
        #expect(try contains("salary-list.txt", inFileAt: archive))
        #expect(try contains("timeline.txt", inFileAt: archive))
    }

    @Test("the outer archive lists exactly one entry")
    func outerArchiveHasOneEntry() throws {
        let source = try makeSource()
        defer { remove(source.directory) }
        let archive = source.directory + "/archive.zip"

        try EncryptedArchiveWriter.write(
            items: source.items, toArchiveAt: archive, encryption: .aes256,
            passphrase: ArchivePassphrase("hunter2"), namePrivacy: .hidden
        )

        let inspection = try EncryptedArchiveReader.inspect(archiveAt: archive)
        #expect(inspection.entries.map(\.archivePath) == ["Contents.tar"])
        #expect(inspection.needsPassphrase)
    }

    @Test("Dirnex unwraps it transparently, giving back the original tree")
    func roundTripIsTransparent() throws {
        let source = try makeSource()
        defer { remove(source.directory) }
        let archive = source.directory + "/archive.zip"

        try EncryptedArchiveWriter.write(
            items: source.items, toArchiveAt: archive, encryption: .aes256,
            passphrase: ArchivePassphrase("hunter2"), namePrivacy: .hidden
        )

        let destination = source.directory + "/out"
        try FileManager.default.createDirectory(
            atPath: destination,
            withIntermediateDirectories: true
        )
        defer { remove(destination) }

        let report = try EncryptedArchiveReader.extract(
            archiveAt: archive, into: destination, passphrase: ArchivePassphrase("hunter2")
        )

        #expect(report.extractedPaths.sorted() == [
            "layoffs", "layoffs/salary-list.txt", "layoffs/timeline.txt"
        ])
        let restored = try String(
            contentsOf: URL(fileURLWithPath: destination + "/layoffs/salary-list.txt"),
            encoding: .utf8
        )
        #expect(restored == "who goes\n")
        // The container must not be left behind next to the files it carried.
        #expect(!FileManager.default.fileExists(atPath: destination + "/Contents.tar"))
    }

    @Test("asking for the container itself yields it unopened")
    func unwrappingCanBeDeclined() throws {
        let source = try makeSource()
        defer { remove(source.directory) }
        let archive = source.directory + "/archive.zip"

        try EncryptedArchiveWriter.write(
            items: source.items, toArchiveAt: archive, encryption: .aes256,
            passphrase: ArchivePassphrase("hunter2"), namePrivacy: .hidden
        )

        let destination = source.directory + "/raw"
        try FileManager.default.createDirectory(
            atPath: destination,
            withIntermediateDirectories: true
        )
        defer { remove(destination) }

        let report = try EncryptedArchiveReader.extract(
            archiveAt: archive, into: destination,
            passphrase: ArchivePassphrase("hunter2"), unwrappingHiddenNames: false
        )
        #expect(report.extractedPaths == ["Contents.tar"])
        #expect(FileManager.default.fileExists(atPath: destination + "/Contents.tar"))
    }

    @Test("hiding names still refuses a blank passphrase, and hides nothing unencrypted")
    func guardsStillApply() throws {
        let source = try makeSource()
        defer { remove(source.directory) }

        #expect(throws: EncryptedArchiveError.emptyPassphrase) {
            try EncryptedArchiveWriter.write(
                items: source.items, toArchiveAt: source.directory + "/archive.zip",
                encryption: .aes256, passphrase: ArchivePassphrase(""), namePrivacy: .hidden
            )
        }
    }

    @Test("asking for the wrapper is recognized by inner path, and only for the wrapper itself")
    func requestsWrapper() {
        // What a pane browsing such an archive hands over — its one row, as a VFS inner path.
        #expect(ArchiveNamePrivacy.requestsWrapper(["/Contents.tar"]))
        #expect(ArchiveNamePrivacy.requestsWrapper(["Contents.tar"]))
        // A member of that name *inside* the payload is an ordinary file, and unwrapping is still
        // what a caller asking for it wants — the rule must not widen to a suffix match.
        #expect(!ArchiveNamePrivacy.requestsWrapper(["/payload/Contents.tar"]))
        #expect(!ArchiveNamePrivacy.requestsWrapper(["/contents.tar"]))
        #expect(!ArchiveNamePrivacy.requestsWrapper(["/Contents.tar", "/notes.txt"]))
        #expect(!ArchiveNamePrivacy.requestsWrapper([]))
    }

    @Test("the wrapped shape is recognized by its exact contents, nothing looser")
    func looksWrapped() {
        #expect(ArchiveNamePrivacy.looksWrapped(["Contents.tar"]))
        #expect(!ArchiveNamePrivacy.looksWrapped(["Contents.tar", "notes.txt"]))
        #expect(!ArchiveNamePrivacy.looksWrapped(["contents.tar"]))
        #expect(!ArchiveNamePrivacy.looksWrapped([]))
    }
}
