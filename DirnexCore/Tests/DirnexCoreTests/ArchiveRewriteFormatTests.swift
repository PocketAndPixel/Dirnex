import Foundation
import Testing

@testable import DirnexCore

/// What a rewrite has to put back that the extracted tree cannot tell it (PLAN.md §M4 / §M19).
///
/// Both properties are inferred from headers alone — no passphrase, nothing decrypted — which is
/// what lets the app decide whether to *ask* for one before any work starts.
@Suite("Archive rewrite format")
struct ArchiveRewriteFormatTests {
    private func inspection(_ entries: [(String, Bool)]) -> EncryptedArchiveReader.Inspection {
        EncryptedArchiveReader.Inspection(entries: entries.map { name, encrypted in
            EncryptedArchiveReader.Entry(
                archivePath: name,
                kind: .regularFile,
                byteSize: 1,
                permissions: 0o644,
                modificationDate: Date(timeIntervalSince1970: 0),
                isEncrypted: encrypted
            )
        })
    }

    @Test("an ordinary archive rewrites as an ordinary archive")
    func plainArchive() {
        let format = ArchiveRewriteFormat.inferred(from: inspection([("a.txt", false)]))
        #expect(format == .plain)
        #expect(!format.needsPassphrase)
    }

    @Test("any encrypted entry makes the whole rewrite encrypted")
    func oneEncryptedEntryIsEnough() {
        // A zip may mix encrypted and plain entries; repacking the plain ones in the clear would
        // silently drop protection from files that had it, so the archive is the unit, not the entry.
        let format = ArchiveRewriteFormat.inferred(
            from: inspection([("plain.txt", false), ("secret.txt", true)])
        )
        #expect(format.encryption == .aes256)
        #expect(format.needsPassphrase)
    }

    @Test("hidden names are recognized by shape and preserved")
    func hiddenNames() {
        let format = ArchiveRewriteFormat.inferred(
            from: inspection([(ArchiveNamePrivacy.wrappedEntryName, true)])
        )
        #expect(format.namePrivacy == .hidden)
        #expect(format.encryption == .aes256)
    }

    @Test("the wrapper name alongside other entries is not a hidden-names archive")
    func wrapperAmongOthersIsVisible() {
        // `looksWrapped` is an exact single-entry match: an archive that merely *contains* a file
        // called Contents.tar must not be re-wrapped, which would bury its real entries one level
        // deeper on every rewrite.
        let format = ArchiveRewriteFormat.inferred(
            from: inspection([(ArchiveNamePrivacy.wrappedEntryName, false), ("notes.md", false)])
        )
        #expect(format.namePrivacy == .visible)
    }

    @Test("an empty archive rewrites as a plain visible one")
    func emptyArchive() {
        #expect(ArchiveRewriteFormat.inferred(from: inspection([])) == .plain)
    }
}

/// The "did the user actually save?" decision, split out of the watcher so it can be exercised
/// without one (PLAN.md §M4 edit-in-place write-back).
@Suite("Edited file revision")
struct EditedFileRevisionTests {
    private let base = EditedFileRevision(
        byteSize: 100, modified: Date(timeIntervalSince1970: 1_000)
    )

    @Test("an unchanged file is not superseded")
    func unchanged() {
        #expect(!base.isSuperseded(by: base))
    }

    @Test("a different size counts even when the timestamp did not move")
    func sizeAlone() {
        // An editor that writes fast enough to land in the same second still changed the file.
        let after = EditedFileRevision(byteSize: 101, modified: base.modified)
        #expect(base.isSuperseded(by: after))
    }

    @Test("a later timestamp counts even when the size is identical")
    func timestampAlone() {
        let after = EditedFileRevision(
            byteSize: 100, modified: Date(timeIntervalSince1970: 1_000.5)
        )
        #expect(base.isSuperseded(by: after))
    }

    @Test("a real file reads back its own size, and a rewrite supersedes it")
    func readsRealFiles() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("revision-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("note.txt")

        try "hello".write(to: file, atomically: true, encoding: .utf8)
        let first = try #require(EditedFileRevision.current(ofFileAt: file.path))
        #expect(first.byteSize == 5)

        // `atomically: true` is the rename-over-the-original save every macOS editor performs, so
        // this is the shape the watcher actually sees — a *new* inode at the same path.
        try "hello there".write(to: file, atomically: true, encoding: .utf8)
        let second = try #require(EditedFileRevision.current(ofFileAt: file.path))
        #expect(first.isSuperseded(by: second))
    }

    @Test("a missing file has no revision, which is not the same as a changed one")
    func missingFileIsNotAChange() {
        // The gap inside an atomic save: the original is renamed away and the replacement is not
        // there yet. Offering to repack a file that does not exist is the failure this prevents.
        #expect(EditedFileRevision.current(ofFileAt: "/nonexistent/nope.txt") == nil)
    }

    @Test("a directory has no revision")
    func directoryHasNoRevision() {
        #expect(EditedFileRevision.current(ofFileAt: NSTemporaryDirectory()) == nil)
    }
}
