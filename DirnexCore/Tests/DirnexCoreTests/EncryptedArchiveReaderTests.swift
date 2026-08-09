import Foundation
import Testing

@testable import DirnexCore

/// The archives under test were written by **`bsdtar`**, not by `EncryptedArchiveWriter`.
///
/// That is the whole point of committing them: a reader checked against our own writer proves the
/// two agree, which is exactly what a shared misunderstanding of the format also produces. The
/// fixtures are the same kind of evidence as the `.DS_Store` the trash tests read (Package.swift's
/// own comment) — real bytes from a producer that has no idea Dirnex exists.
///
/// Both were made with:
///
///     bsdtar -c -f encrypted-aes256-bsdtar.zip --format zip \
///            --options zip:encryption=aes256 --passphrase 'dirnex-test-passphrase' \
///            -C <staging> notes link.txt
///
/// holding `notes/hello.txt` (18 bytes), `notes/nested/deep.txt` (11 bytes), the two directories,
/// and `link.txt` → `notes/hello.txt`.
@Suite("EncryptedArchiveReader")
struct EncryptedArchiveReaderTests {
    private static let passphrase = "dirnex-test-passphrase"

    private func fixture(_ name: String) throws -> String {
        let url = try #require(
            Bundle.module.url(forResource: name, withExtension: "zip", subdirectory: "Fixtures"),
            "missing fixture \(name).zip"
        )
        return url.path
    }

    private func scratchDirectory() throws -> String {
        let path = NSTemporaryDirectory() + "dirnex-reader-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
        return path
    }

    private func remove(_ path: String) { try? FileManager.default.removeItem(atPath: path) }

    private func contents(of path: String) throws -> String {
        try String(contentsOf: URL(fileURLWithPath: path), encoding: .utf8)
    }

    // MARK: - Inspection

    @Test("an encrypted archive lists its contents with no passphrase at all")
    func inspectionNeedsNoPassphrase() throws {
        let inspection = try EncryptedArchiveReader.inspect(
            archiveAt: fixture("encrypted-aes256-bsdtar")
        )

        #expect(inspection.needsPassphrase)
        #expect(inspection.entries.map(\.archivePath).sorted() == [
            "link.txt", "notes/", "notes/hello.txt", "notes/nested/", "notes/nested/deep.txt"
        ])
        // 18 + 11; directories and the symlink contribute nothing.
        #expect(inspection.totalByteSize == 29)
    }

    @Test("only the data is encrypted — directories and the symlink are not")
    func onlyFileDataIsEncrypted() throws {
        let inspection = try EncryptedArchiveReader.inspect(
            archiveAt: fixture("encrypted-aes256-bsdtar")
        )
        let encrypted = inspection.entries.filter(\.isEncrypted).map(\.archivePath).sorted()
        #expect(encrypted == ["notes/hello.txt", "notes/nested/deep.txt"])
    }

    @Test("a plain archive reports that it needs nothing")
    func plainArchiveNeedsNoPassphrase() throws {
        let inspection = try EncryptedArchiveReader.inspect(archiveAt: fixture("plain-bsdtar"))
        #expect(!inspection.needsPassphrase)
        #expect(inspection.entries.count == 5)
    }

    @Test("entry kinds survive the round trip through bsdtar's zip")
    func entryKinds() throws {
        let inspection = try EncryptedArchiveReader.inspect(archiveAt: fixture("plain-bsdtar"))
        let byName = Dictionary(
            uniqueKeysWithValues: inspection.entries.map { ($0.archivePath, $0) }
        )

        #expect(byName["notes/"]?.kind == .directory)
        #expect(byName["notes/hello.txt"]?.kind == .regularFile)
        #expect(byName["link.txt"]?.kind == .symbolicLink(target: "notes/hello.txt"))
    }

    // MARK: - Extraction

    @Test("the right passphrase extracts bsdtar's archive byte for byte")
    func extractsWithCorrectPassphrase() throws {
        let destination = try scratchDirectory()
        defer { remove(destination) }

        let report = try EncryptedArchiveReader.extract(
            archiveAt: fixture("encrypted-aes256-bsdtar"),
            into: destination,
            passphrase: ArchivePassphrase(Self.passphrase)
        )

        #expect(report.refused.isEmpty)
        #expect(try contents(of: destination + "/notes/hello.txt") == "hello from bsdtar\n")
        #expect(try contents(of: destination + "/notes/nested/deep.txt") == "deep bytes\n")

        var linkStatus = stat()
        #expect(lstat(destination + "/link.txt", &linkStatus) == 0)
        #expect((linkStatus.st_mode & S_IFMT) == S_IFLNK)
    }

    @Test("a wrong passphrase is reported as such, not as a damaged archive")
    func wrongPassphraseIsReportedAsSuch() throws {
        let destination = try scratchDirectory()
        defer { remove(destination) }

        // This is the test that pins `LibArchive.isIncorrectPassphrase`, which has to read
        // libarchive's English because the return code cannot tell the two failures apart. If a
        // future libarchive rewords its message, this fails loudly here rather than silently
        // degrading every mistyped passphrase into "this archive is damaged".
        #expect(throws: EncryptedArchiveError.incorrectPassphrase) {
            try EncryptedArchiveReader.extract(
                archiveAt: fixture("encrypted-aes256-bsdtar"),
                into: destination,
                passphrase: ArchivePassphrase("not the passphrase")
            )
        }
    }

    @Test("extracting without a passphrase asks for one instead of failing obscurely")
    func missingPassphraseIsNamed() throws {
        let destination = try scratchDirectory()
        defer { remove(destination) }

        #expect(throws: EncryptedArchiveError.passphraseRequired) {
            try EncryptedArchiveReader.extract(
                archiveAt: fixture("encrypted-aes256-bsdtar"), into: destination, passphrase: nil
            )
        }
    }

    @Test("a plain archive extracts even when a passphrase is offered anyway")
    func passphraseOnAPlainArchiveIsHarmless() throws {
        let destination = try scratchDirectory()
        defer { remove(destination) }

        try EncryptedArchiveReader.extract(
            archiveAt: fixture("plain-bsdtar"),
            into: destination,
            passphrase: ArchivePassphrase("irrelevant")
        )
        #expect(try contents(of: destination + "/notes/hello.txt") == "hello from bsdtar\n")
    }

    @Test("progress ends at the archive's own declared total")
    func progressReachesTheTotal() throws {
        let destination = try scratchDirectory()
        defer { remove(destination) }

        var last: EncryptedArchiveReader.Progress?
        try EncryptedArchiveReader.extract(
            archiveAt: fixture("encrypted-aes256-bsdtar"),
            into: destination,
            passphrase: ArchivePassphrase(Self.passphrase),
            onProgress: { last = $0 }
        )

        let final = try #require(last)
        #expect(final.bytesExtracted == 29)
        #expect(final.totalBytes == 29)
    }

    @Test("canceling stops the extraction")
    func cancellation() throws {
        let destination = try scratchDirectory()
        defer { remove(destination) }

        #expect(throws: CancellationError.self) {
            try EncryptedArchiveReader.extract(
                archiveAt: fixture("encrypted-aes256-bsdtar"),
                into: destination,
                passphrase: ArchivePassphrase(Self.passphrase),
                isCancelled: { true }
            )
        }
    }

    // MARK: - Round trip

    @Test("what the writer produces, the reader reads back unchanged")
    func writerReaderRoundTrip() throws {
        let source = try scratchDirectory()
        defer { remove(source) }
        try FileManager.default.createDirectory(
            atPath: source + "/tree/inner", withIntermediateDirectories: true
        )
        let body = String(repeating: "round trip bytes\n", count: 5000)
        try Data(body.utf8).write(to: URL(fileURLWithPath: source + "/tree/inner/big.txt"))

        let archive = source + "/out.zip"
        let items = try ArchiveSourceEnumerator.items(inDirectory: source, names: ["tree"])
        try EncryptedArchiveWriter.write(
            items: items, toArchiveAt: archive,
            encryption: .aes256, passphrase: ArchivePassphrase("round trip")
        )

        let destination = try scratchDirectory()
        defer { remove(destination) }
        try EncryptedArchiveReader.extract(
            archiveAt: archive, into: destination, passphrase: ArchivePassphrase("round trip")
        )

        // Larger than one 128 KiB chunk on purpose: the chunked write and chunked read loops are
        // where an off-by-one costs you a corrupted file rather than an error.
        #expect(try contents(of: destination + "/tree/inner/big.txt") == body)
    }
}
