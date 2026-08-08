import Foundation
import Testing

@testable import DirnexCore

/// What these assert, and what they deliberately do not.
///
/// The claim that matters for an archive someone will send to a stranger is **"is this the format
/// every other archiver reads"**, and the only honest way to check it is to read the bytes against
/// the published shape of the format. So `ZipBytes` below is written out by hand, from the zip
/// specification's field offsets, rather than borrowed from `EncryptedArchiveWriter` — reusing the
/// writer's own idea of a header would prove the two agree, not that either is right. It is the same
/// rule `ChecksumEngineTests` follows by pinning digests the *system* tools produced, and the same
/// one docs/NOTES.md draws for the M18 renderer's scheme reader.
///
/// Round-tripping is tested in `EncryptedArchiveReaderTests`, against archives **`bsdtar` wrote**,
/// for the same reason.
@Suite("EncryptedArchiveWriter")
struct EncryptedArchiveWriterTests {
    // MARK: - A hand-written reader for the few header fields under test

    /// The AES extra field (`0x9901`) as WinZip defines it.
    private struct AESExtraField: Equatable {
        let version: Int
        let vendor: String
        let strength: Int
        /// The real compression method, hidden behind method 99 in the header proper.
        let innerMethod: Int
    }

    /// One local file header's fields, as the zip specification lays them out.
    private struct ZipEntryHeader {
        /// 99 is the WinZip AES marker, 8 is deflate, 0 is stored.
        let compressionMethod: Int
        let aes: AESExtraField?
    }

    /// A hand-written reader for the few zip header fields these tests need, at the offsets the
    /// format specification gives them. Nothing here imports from the code under test.
    ///
    /// Entries are looked up **by name**, not by position, which is not fussiness: the first local
    /// header in a packed folder belongs to the folder itself, and a directory entry has no data, so
    /// it is stored with method 0 and carries no AES field however the archive was encrypted. A
    /// probe that read "the first entry" would report method 0 for a perfectly good AES-256 archive.
    private struct ZipBytes {
        let data: Data

        init(contentsOf path: String) throws {
            data = try Data(contentsOf: URL(fileURLWithPath: path))
        }

        private func uint16(at offset: Int) -> Int {
            Int(data[offset]) | (Int(data[offset + 1]) << 8)
        }

        /// `PK\u{3}\u{4}` — the local file header signature.
        var startsWithLocalFileHeader: Bool {
            data.count > 4 && data[0] == 0x50 && data[1] == 0x4B && data[2] == 0x03 && data[3] == 0x04
        }

        /// The local header for `name`, or `nil` if the archive has no such entry.
        func entry(named name: String) -> ZipEntryHeader? {
            let signature = Data([0x50, 0x4B, 0x03, 0x04])
            var cursor = data.startIndex
            while let found = data.range(of: signature, in: cursor..<data.endIndex) {
                let start = found.lowerBound
                guard start + 30 <= data.count else { return nil }
                let nameLength = uint16(at: start + 26)
                let extraLength = uint16(at: start + 28)
                let nameStart = start + 30
                let extraStart = nameStart + nameLength
                guard extraStart + extraLength <= data.count else { return nil }

                let entryName = String(bytes: data[nameStart..<extraStart], encoding: .utf8)
                if entryName == name {
                    return ZipEntryHeader(
                        compressionMethod: uint16(at: start + 8),
                        aes: aesField(in: extraStart..<(extraStart + extraLength))
                    )
                }
                cursor = found.upperBound
            }
            return nil
        }

        /// Walks the extra-field area as (id, size, payload) triples and returns the `0x9901` one.
        /// Walking rather than searching for the two marker bytes matters: `0x9901` is an ordinary
        /// byte pair that turns up inside compressed data often enough to fool a global scan.
        private func aesField(in range: Range<Int>) -> AESExtraField? {
            var cursor = range.lowerBound
            while cursor + 4 <= range.upperBound {
                let identifier = uint16(at: cursor)
                let size = uint16(at: cursor + 2)
                let payload = cursor + 4
                guard payload + size <= range.upperBound else { return nil }
                if identifier == 0x9901, size >= 7 {
                    let vendor = String(bytes: data[(payload + 2)..<(payload + 4)], encoding: .utf8)
                    return AESExtraField(
                        version: uint16(at: payload),
                        vendor: vendor ?? "",
                        strength: Int(data[payload + 4]),
                        innerMethod: uint16(at: payload + 5)
                    )
                }
                cursor = payload + size
            }
            return nil
        }

        /// Whether the bytes contain this name in the clear. Zip never encrypts the central
        /// directory, so this is *expected* to be true even for an encrypted archive — the assertion
        /// exists to pin that fact rather than to be reassured by it.
        func containsPlaintext(_ name: String) -> Bool {
            data.range(of: Data(name.utf8)) != nil
        }
    }

    // MARK: - Fixture helpers

    /// A scratch directory with two files and a nested folder, plus the items describing them.
    private func makeSource() throws -> (directory: String, items: [ArchiveSourceItem]) {
        let root = NSTemporaryDirectory() + "dirnex-writer-\(UUID().uuidString)"
        let nested = root + "/notes/nested"
        try FileManager.default.createDirectory(atPath: nested, withIntermediateDirectories: true)
        try Data("hello from dirnex\n".utf8).write(
            to: URL(fileURLWithPath: root + "/notes/hello.txt")
        )
        try Data("deep bytes\n".utf8).write(to: URL(fileURLWithPath: nested + "/deep.txt"))
        let items = try ArchiveSourceEnumerator.items(inDirectory: root, names: ["notes"])
        return (root, items)
    }

    private func remove(_ path: String) {
        try? FileManager.default.removeItem(atPath: path)
    }

    // MARK: - Format

    @Test("an encrypted archive is WinZip AES-256, the format 7-Zip and WinRAR read")
    func writesWinZipAES256() throws {
        let source = try makeSource()
        defer { remove(source.directory) }
        let archive = source.directory + ".zip"
        defer { remove(archive) }

        try EncryptedArchiveWriter.write(
            items: source.items,
            toArchiveAt: archive,
            encryption: .aes256,
            passphrase: ArchivePassphrase("correct horse battery staple")
        )

        let bytes = try ZipBytes(contentsOf: archive)
        #expect(bytes.startsWithLocalFileHeader)

        let file = try #require(bytes.entry(named: "notes/hello.txt"))
        #expect(file.compressionMethod == 99)
        let aes = try #require(file.aes)
        #expect(aes.version == 2)
        #expect(aes.vendor == "AE")
        #expect(aes.strength == 3) // 1 = AES-128, 2 = AES-192, 3 = AES-256
        #expect(aes.innerMethod == 8) // deflate, applied before encryption
    }

    @Test("a directory entry carries no encryption, because it carries no data")
    func directoryEntriesAreNotEncrypted() throws {
        let source = try makeSource()
        defer { remove(source.directory) }
        let archive = source.directory + ".zip"
        defer { remove(archive) }

        try EncryptedArchiveWriter.write(
            items: source.items,
            toArchiveAt: archive,
            encryption: .aes256,
            passphrase: ArchivePassphrase("correct horse battery staple")
        )

        // Worth pinning rather than assuming: this is what made the first version of `ZipBytes`
        // report method 0 for a correctly encrypted archive, and it is the shape any future probe
        // over these bytes has to know about.
        let directory = try #require(ZipBytes(contentsOf: archive).entry(named: "notes/"))
        #expect(directory.compressionMethod == 0)
        #expect(directory.aes == nil)
    }

    @Test("an unencrypted archive carries no AES marker at all")
    func unencryptedArchiveIsOrdinary() throws {
        let source = try makeSource()
        defer { remove(source.directory) }
        let archive = source.directory + ".zip"
        defer { remove(archive) }

        try EncryptedArchiveWriter.write(
            items: source.items, toArchiveAt: archive, encryption: .none, passphrase: nil
        )

        let file = try #require(ZipBytes(contentsOf: archive).entry(named: "notes/hello.txt"))
        #expect(file.compressionMethod != 99)
        #expect(file.aes == nil)
    }

    @Test("encryption hides the contents and not the file names — the leak, pinned")
    func encryptionDoesNotHideNames() throws {
        let source = try makeSource()
        defer { remove(source.directory) }
        let archive = source.directory + ".zip"
        defer { remove(archive) }

        try EncryptedArchiveWriter.write(
            items: source.items,
            toArchiveAt: archive,
            encryption: .aes256,
            passphrase: ArchivePassphrase("correct horse battery staple")
        )

        let bytes = try ZipBytes(contentsOf: archive)
        // The payload is gone…
        #expect(!bytes.containsPlaintext("hello from dirnex"))
        // …and every name is still there in the clear. This is a property of zip, not a defect in
        // the writer, and `ArchivePacking.NamePrivacy` is the only thing that answers it. Asserted
        // so that a future change claiming to fix it has to update this test deliberately.
        #expect(bytes.containsPlaintext("notes/hello.txt"))
        #expect(bytes.containsPlaintext("notes/nested/deep.txt"))
    }

    // MARK: - Guards

    @Test("encrypting with a blank passphrase is refused before anything is written")
    func emptyPassphraseIsRefused() throws {
        let source = try makeSource()
        defer { remove(source.directory) }
        let archive = source.directory + ".zip"

        #expect(throws: EncryptedArchiveError.emptyPassphrase) {
            try EncryptedArchiveWriter.write(
                items: source.items,
                toArchiveAt: archive,
                encryption: .aes256,
                passphrase: ArchivePassphrase("")
            )
        }
        #expect(!FileManager.default.fileExists(atPath: archive))
    }

    @Test("encrypting with no passphrase at all is refused")
    func missingPassphraseIsRefused() throws {
        let source = try makeSource()
        defer { remove(source.directory) }

        #expect(throws: EncryptedArchiveError.emptyPassphrase) {
            try EncryptedArchiveWriter.write(
                items: source.items,
                toArchiveAt: source.directory + ".zip",
                encryption: .aes256,
                passphrase: nil
            )
        }
    }

    @Test("an empty selection is refused rather than producing an empty archive")
    func nothingToArchive() {
        #expect(throws: EncryptedArchiveError.nothingToArchive) {
            try EncryptedArchiveWriter.write(
                items: [], toArchiveAt: "/tmp/unused.zip", encryption: .none, passphrase: nil
            )
        }
    }

    // MARK: - Progress and cancellation

    @Test("progress ends at the total, and the total counts file bytes only")
    func progressReachesTheTotal() throws {
        let source = try makeSource()
        defer { remove(source.directory) }
        let archive = source.directory + ".zip"
        defer { remove(archive) }

        var last: EncryptedArchiveWriter.Progress?
        try EncryptedArchiveWriter.write(
            items: source.items,
            toArchiveAt: archive,
            encryption: .aes256,
            passphrase: ArchivePassphrase("pw"),
            onProgress: { last = $0 }
        )

        let final = try #require(last)
        let expectedBytes = ArchiveSourceEnumerator.totalByteSize(of: source.items)
        #expect(final.bytesWritten == expectedBytes)
        #expect(final.totalBytes == expectedBytes)
        #expect(final.itemsWritten == source.items.count)
        // "hello from dirnex\n" is 18 bytes, "deep bytes\n" is 11; the two directories add nothing.
        #expect(expectedBytes == 29)
    }

    @Test("cancelling leaves neither an archive nor a temporary file behind")
    func cancellationCleansUp() throws {
        let source = try makeSource()
        defer { remove(source.directory) }
        let archive = source.directory + ".zip"
        defer { remove(archive) }

        #expect(throws: CancellationError.self) {
            try EncryptedArchiveWriter.write(
                items: source.items,
                toArchiveAt: archive,
                encryption: .aes256,
                passphrase: ArchivePassphrase("pw"),
                isCancelled: { true }
            )
        }

        #expect(!FileManager.default.fileExists(atPath: archive))
        // The temporary is a hidden sibling of the destination, so a leak would show up here.
        let siblings = try FileManager.default.contentsOfDirectory(
            atPath: (archive as NSString).deletingLastPathComponent
        )
        #expect(!siblings.contains { $0.hasPrefix(".dirnex-pack-") })
    }

    @Test("a failed pack leaves an existing archive at that path untouched")
    func failureDoesNotDestroyTheOldArchive() throws {
        let source = try makeSource()
        defer { remove(source.directory) }
        let archive = source.directory + ".zip"
        defer { remove(archive) }

        try EncryptedArchiveWriter.write(
            items: source.items, toArchiveAt: archive, encryption: .none, passphrase: nil
        )
        let original = try Data(contentsOf: URL(fileURLWithPath: archive))

        #expect(throws: CancellationError.self) {
            try EncryptedArchiveWriter.write(
                items: source.items,
                toArchiveAt: archive,
                encryption: .aes256,
                passphrase: ArchivePassphrase("pw"),
                isCancelled: { true }
            )
        }

        let afterwards = try Data(contentsOf: URL(fileURLWithPath: archive))
        #expect(afterwards == original)
    }
}
