import DirnexCore
import Foundation
import Testing

@testable import Dirnex

/// Rewriting an **encrypted** archive (PLAN.md §M4 archive writes × §M19 encryption).
///
/// Before this route existed every rewrite went through `bsdtar`, which has no way to take a
/// passphrase — so F8 delete and F5/paste add inside an encrypted archive failed outright. The
/// claims worth pinning are not that the rewrite happens but that it puts the archive back *as it
/// was*: still encrypted, still opening with the same passphrase, still hiding its names if it did.
/// And that every failure leaves the original exactly where it was, since a half-rewritten archive
/// is unrecoverable in a way a failed one is not.
@Suite("Encrypted archive rewrite")
struct ArchiveWriterEncryptedTests {
    // MARK: - Round trips

    @Test("deleting a member keeps the archive encrypted and openable")
    func deletePreservesEncryption() throws {
        let fixture = try Fixture()

        try ArchiveWriter.delete(
            innerPaths: ["/one.txt"],
            fromArchiveAt: fixture.archive,
            passphrase: Fixture.passphrase
        )

        let inspection = try EncryptedArchiveReader.inspect(archiveAt: fixture.archive)
        #expect(inspection.needsPassphrase)
        #expect(inspection.entries.map(\.archivePath).sorted() == ["two.txt"])
        // The survivor still opens with the same passphrase — the claim a user actually cares about.
        #expect(try fixture.readBack("two.txt") == "second")
    }

    @Test("adding a file keeps the archive encrypted, and the new member is encrypted too")
    func addPreservesEncryption() throws {
        let fixture = try Fixture()
        let extra = fixture.directory.appendingPathComponent("added.txt")
        try "added".write(to: extra, atomically: true, encoding: .utf8)

        try ArchiveWriter.add(
            localPaths: [extra.path],
            toInnerDirectory: "/",
            ofArchiveAt: fixture.archive,
            passphrase: Fixture.passphrase
        )

        let inspection = try EncryptedArchiveReader.inspect(archiveAt: fixture.archive)
        #expect(
            inspection.entries.map(\.archivePath).sorted() == ["added.txt", "one.txt", "two.txt"]
        )
        // Every entry, not just the pre-existing ones: a file added into an encrypted archive that
        // came back in the clear would be the quietest possible loss of protection.
        let unprotected = inspection.entries.filter { !$0.isEncrypted }.map(\.archivePath)
        #expect(unprotected.isEmpty)
        #expect(try fixture.readBack("added.txt") == "added")
    }

    @Test("an edited member written back replaces it and nothing else")
    func writeBackReplacesOneMember() throws {
        let fixture = try Fixture()
        // What editing in place does: the extracted copy, edited, added back where it came from.
        let edited = fixture.directory.appendingPathComponent("one.txt")
        try "first, revised".write(to: edited, atomically: true, encoding: .utf8)

        try ArchiveWriter.add(
            localPaths: [edited.path],
            toInnerDirectory: "/",
            ofArchiveAt: fixture.archive,
            passphrase: Fixture.passphrase
        )

        let inspection = try EncryptedArchiveReader.inspect(archiveAt: fixture.archive)
        #expect(inspection.entries.count == 2)
        #expect(try fixture.readBack("one.txt") == "first, revised")
        #expect(try fixture.readBack("two.txt") == "second")
    }

    @Test("a hidden-names archive is still hidden after a rewrite")
    func hiddenNamesSurviveARewrite() throws {
        let fixture = try Fixture(namePrivacy: .hidden)
        // Before: the outer archive lists only the wrapper.
        let before = try EncryptedArchiveReader.inspect(archiveAt: fixture.archive)
        #expect(ArchiveNamePrivacy.looksWrapped(before.entries.map(\.archivePath)))

        try ArchiveWriter.delete(
            innerPaths: ["/one.txt"],
            fromArchiveAt: fixture.archive,
            passphrase: Fixture.passphrase
        )

        // After: still exactly one entry, still the wrapper. A rewrite that forgot this would
        // publish every file name of an archive whose whole point was hiding them — and it would do
        // it silently, because the *contents* would still be perfectly correct.
        let after = try EncryptedArchiveReader.inspect(archiveAt: fixture.archive)
        #expect(ArchiveNamePrivacy.looksWrapped(after.entries.map(\.archivePath)))
        #expect(try fixture.readBack("two.txt") == "second")
    }

    @Test("an unencrypted archive still rewrites through the bsdtar route")
    func plainArchiveIsUnaffected() throws {
        let fixture = try Fixture(encryption: .none)
        try ArchiveWriter.delete(innerPaths: ["/one.txt"], fromArchiveAt: fixture.archive)

        let inspection = try EncryptedArchiveReader.inspect(archiveAt: fixture.archive)
        #expect(!inspection.needsPassphrase)
        // **The two routes spell their entry names differently, and that is pre-existing.** `bsdtar`
        // packs `.` — so an archive it rewrites carries `./` and `./two.txt` — while the encrypted
        // route enumerates the top level and writes bare names, the same shape the pack sheet
        // produces. Asserted rather than normalized: both browse identically (the `./` form has
        // shipped since archive writes did), so making them agree would be a change to the
        // unencrypted path for the benefit of a test rather than a user.
        #expect(inspection.entries.map(\.archivePath).sorted() == ["./", "./two.txt"])
    }

    // MARK: - Failures leave the original alone

    @Test("with no passphrase the rewrite refuses and the archive is untouched")
    func missingPassphraseLeavesOriginal() throws {
        let fixture = try Fixture()
        let before = try fixture.archiveBytes()

        #expect(throws: EncryptedArchiveError.passphraseRequired) {
            try ArchiveWriter.delete(innerPaths: ["/one.txt"], fromArchiveAt: fixture.archive)
        }
        #expect(try fixture.archiveBytes() == before)
    }

    @Test("with the wrong passphrase the rewrite refuses and the archive is untouched")
    func wrongPassphraseLeavesOriginal() throws {
        let fixture = try Fixture()
        let before = try fixture.archiveBytes()

        // `incorrectPassphrase` specifically, because that is what re-raises the prompt rather than
        // dead-ending in an alert (see `withArchivePassphrase`).
        #expect(throws: EncryptedArchiveError.incorrectPassphrase) {
            try ArchiveWriter.delete(
                innerPaths: ["/one.txt"],
                fromArchiveAt: fixture.archive,
                passphrase: ArchivePassphrase("not-it")
            )
        }
        #expect(try fixture.archiveBytes() == before)
    }

    @Test("no scratch archive is left beside the original when a rewrite fails")
    func failureLeavesNoLitter() throws {
        let fixture = try Fixture()
        #expect(throws: (any Error).self) {
            try ArchiveWriter.delete(
                innerPaths: ["/one.txt"],
                fromArchiveAt: fixture.archive,
                passphrase: ArchivePassphrase("not-it")
            )
        }
        // The rewrite builds its replacement as a hidden sibling; a failed one that stayed behind
        // would show up in the user's folder as a dot-file nobody put there.
        let siblings = try FileManager.default
            .contentsOfDirectory(atPath: fixture.directory.path)
            .filter { $0 != "source" && $0 != "fixture.zip" && $0 != "one.txt" }
        #expect(siblings.isEmpty)
    }

    /// A real archive on disk, written by the app's own writer so every rewrite under test reads
    /// bytes of exactly the shape Dirnex produces. Removed with the test's temp directory.
    private struct Fixture {
        static let passphrase = ArchivePassphrase("correct horse")

        let directory: URL
        let archive: String

        init(
            encryption: ArchiveEncryption = .aes256,
            namePrivacy: ArchiveNamePrivacy = .visible
        ) throws {
            directory = FileManager.default.temporaryDirectory
                .appendingPathComponent("ArchiveWriterEncrypted-\(UUID().uuidString)")
            let source = directory.appendingPathComponent("source", isDirectory: true)
            try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
            try "first".write(
                to: source.appendingPathComponent("one.txt"), atomically: true, encoding: .utf8
            )
            try "second".write(
                to: source.appendingPathComponent("two.txt"), atomically: true, encoding: .utf8
            )

            archive = directory.appendingPathComponent("fixture.zip").path
            try EncryptedArchiveWriter.write(
                items: try ArchiveSourceEnumerator.items(
                    inDirectory: source.path, names: ["one.txt", "two.txt"]
                ),
                toArchiveAt: archive,
                encryption: encryption,
                passphrase: encryption.isEncrypted ? Self.passphrase : nil,
                namePrivacy: namePrivacy
            )
        }

        func archiveBytes() throws -> Data {
            try Data(contentsOf: URL(fileURLWithPath: archive))
        }

        /// Extract the whole archive somewhere fresh and read one member back as text — the check
        /// that the rewrite produced an archive that still *opens*, not merely one that parses.
        func readBack(_ name: String) throws -> String {
            let out = directory.appendingPathComponent("read-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: out) }
            _ = try EncryptedArchiveReader.extract(
                archiveAt: archive, into: out.path, passphrase: Self.passphrase
            )
            return try String(
                contentsOf: out.appendingPathComponent(name), encoding: .utf8
            )
        }
    }
}
