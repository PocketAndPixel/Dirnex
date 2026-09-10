import CArchiveShim
import Foundation

/// Reads and extracts zip archives through the system libarchive, including AES-encrypted ones.
///
/// Dirnex already browses and extracts archives through `bsdtar`; this exists for the case that path
/// cannot serve, which is the same one that motivated the writer — a passphrase has nowhere safe to
/// go on a `bsdtar` command line, and its interactive prompt cannot be answered from a non-tty at
/// all. It also handles the *unencrypted* case, because an extract sheet that asks for a passphrase
/// only when needed has to be able to open both without changing engines mid-flight.
///
/// Everything here treats the archive as **hostile input**. See ``ArchiveEntryPath`` for why that is
/// not paranoia, and `extractionDirectory(…)` below for the second half of it.
public enum EncryptedArchiveReader {
    /// One entry, as read from the archive's headers — no data, no passphrase required.
    public struct Entry: Sendable, Equatable {
        public let archivePath: String
        public let kind: ArchiveSourceItem.Kind
        public let byteSize: Int64
        public let permissions: mode_t
        public let modificationDate: Date
        /// This entry's *data* is encrypted. Its name is not, and cannot be, in any zip.
        public let isEncrypted: Bool
    }

    /// What the archive holds, learned without decrypting anything.
    public struct Inspection: Sendable, Equatable {
        public let entries: [Entry]
        /// Any entry's data is encrypted, so extraction will need a passphrase.
        public var needsPassphrase: Bool { entries.contains { $0.isEncrypted } }

        /// Bytes that will actually be written — regular files only, since a directory and a symlink
        /// carry none and counting them gives a bar that never fills.
        public var totalByteSize: Int64 { totalByteSize(matching: .everything) }

        /// The same count over the members an extraction is going to place. A filtered extraction
        /// measured against the *archive's* total draws a bar that stops a hundredth of the way
        /// along and reports done, which reads as a transfer that failed.
        public func totalByteSize(matching filter: ArchiveMemberFilter) -> Int64 {
            entries.reduce(into: 0) { total, entry in
                guard case .regularFile = entry.kind else { return }
                guard filter.includes(entryNamed: entry.archivePath) else { return }
                total += entry.byteSize
            }
        }
    }

    /// An entry the extractor would not place, and why.
    public struct Refusal: Sendable, Equatable {
        /// The name exactly as the archive spelled it — including whatever `../` it carried, since
        /// that is what the user needs to see to judge the archive they were sent.
        public let name: String
        public let reason: ArchiveEntryPath.Refusal
    }

    /// What an extraction actually did. Refusals are *reported*, never silent: an archive that
    /// listed nine files and produced eight has to say which one it would not place and why.
    public struct ExtractionReport: Sendable, Equatable {
        public let extractedPaths: [String]
        public let refused: [Refusal]
    }

    /// Progress through an extraction, in bytes of entry data.
    public struct Progress: Sendable, Equatable {
        public let bytesExtracted: Int64
        public let totalBytes: Int64
        public let currentName: String
    }

    /// The two callbacks an extraction reports through. Bundled because they always travel together
    /// and are handed *down* unchanged: a wrapped archive's inner extraction reports through the
    /// same pair the outer one was given, so the user sees one operation rather than two.
    struct Reporting {
        let onProgress: (Progress) -> Void
        let isCancelled: () -> Bool
    }

    public static let chunkSize = 128 * 1024

    // MARK: - Inspection

    /// Lists the archive without decrypting it.
    ///
    /// This is what lets the app ask for a passphrase only when one is needed, and — because a zip's
    /// central directory is never encrypted — it is also what lets an encrypted archive show its
    /// contents in a pane before anyone has typed anything.
    ///
    /// - Parameter nameEncoding: The code page the entry names are stored in, when they are not
    ///   UTF-8. `nil` — the default, and the only thing any caller wanted before legacy archives
    ///   were readable — means "the names are UTF-8", and an archive whose names are not then throws
    ///   ``EncryptedArchiveError/entryNameNotUTF8`` exactly as it always did.
    public static func inspect(
        archiveAt path: String,
        nameEncoding: ArchiveNameEncoding? = nil
    ) throws -> Inspection {
        let handle = try openForReading(path, passphrase: nil, nameEncoding: nameEncoding)
        var entries: [Entry] = []
        while true {
            var raw: OpaquePointer?
            let status = archive_read_next_header(handle.raw, &raw)
            if status == LibArchive.eof { break }
            guard status == LibArchive.ok || status == LibArchive.warn, let raw else {
                throw failure(handle)
            }
            guard let entry = makeEntry(raw) else {
                throw EncryptedArchiveError.entryNameNotUTF8(
                    archive: (path as NSString).lastPathComponent
                )
            }
            entries.append(entry)
        }
        return Inspection(entries: entries)
    }

    /// Whether any entry's *data* is encrypted, answered **without decoding a single name**.
    ///
    /// ``Inspection/needsPassphrase`` answers the same question and cannot be asked of a *legacy*
    /// archive at all: ``inspect(archiveAt:nameEncoding:)`` throws on the first name it cannot
    /// decode, so a caller reaching for it learns nothing about the encryption of exactly the
    /// archives that have two things wrong with them at once. Measured 2026-09-09, that gap was
    /// silent and expensive — the app read the throw as "no passphrase needed" and handed an
    /// AES-256 archive to `bsdtar`, which spent six seconds printing `Enter passphrase:` at a
    /// stream nobody reads and then wrote a file of **zeros** under the right name and the right
    /// size, which the caller's own "did anything land" guard reported as a success.
    ///
    /// Nothing here needs a name to be representable, because encryption is a property of the
    /// entry's data and `archive_entry_is_encrypted` reads it straight off the raw header. It costs
    /// headers rather than the archive, exactly as ``inspect(archiveAt:nameEncoding:)`` does, and it
    /// stops at the first encrypted entry.
    ///
    /// It takes no code page **on purpose**: the answer cannot depend on one, and accepting the
    /// parameter would invite a caller to pass `nil` and get the old wrong answer back.
    public static func holdsEncryptedEntries(archiveAt path: String) throws -> Bool {
        let handle = try openForReading(path, passphrase: nil, nameEncoding: nil)
        while true {
            var raw: OpaquePointer?
            let status = archive_read_next_header(handle.raw, &raw)
            if status == LibArchive.eof { return false }
            guard status == LibArchive.ok || status == LibArchive.warn, let raw else {
                throw failure(handle)
            }
            if archive_entry_is_encrypted(raw) != 0 { return true }
        }
    }

    /// Up to `limit` of the archive's *non-ASCII* entry names, as `encoding` reads them — what a
    /// chooser previews so somebody can recognize their own language and pick.
    ///
    /// `nil` back means **this encoding does not fit this archive**: libarchive answers NULL for a
    /// byte that is unmapped in the declared code page, which is a definite no rather than a guess.
    /// A code page that fits but is *wrong* cannot answer `nil` — it returns well-formed nonsense
    /// (the CP866 fixture read as CP1251 is `Џ ­®а ¬ .txt`), which is the whole reason this returns
    /// names for a person to look at instead of a verdict.
    ///
    /// **Called with `encoding: nil` it is also the detector.** `nil` back then means the names are
    /// not UTF-8, which is exactly the condition that makes the choice worth offering; a caller
    /// needs no separate probe.
    ///
    /// Only non-ASCII names are sampled because an ASCII one looks identical under every candidate
    /// and would tell the reader nothing. Reading stops as soon as `limit` are in hand, so this
    /// costs headers rather than the archive — but that is also its one honest limit: an
    /// unrepresentable name *after* those is not seen, so a fitting answer is evidence about the
    /// sample and not a promise about every entry.
    public static func nameSamples(
        archiveAt path: String,
        encoding: ArchiveNameEncoding?,
        limit: Int = 5
    ) throws -> [String]? {
        let handle = try openForReading(path, passphrase: nil, nameEncoding: encoding)
        var samples: [String] = []
        while samples.count < limit {
            var raw: OpaquePointer?
            let status = archive_read_next_header(handle.raw, &raw)
            if status == LibArchive.eof { break }
            guard status == LibArchive.ok || status == LibArchive.warn, let raw else {
                throw failure(handle)
            }
            guard let namePointer = archive_entry_pathname_utf8(raw) else { return nil }
            let name = String(cString: namePointer)
            if name.contains(where: { !$0.isASCII }) { samples.append(name) }
        }
        return samples
    }

    // MARK: - libarchive plumbing

    /// Internal rather than `private` because the extraction pass lives in a companion file and
    /// Swift's `private` does not cross files (docs/NOTES.md ▸ Lint ceilings and file splitting).
    static func openForReading(
        _ path: String,
        passphrase: ArchivePassphrase?,
        nameEncoding: ArchiveNameEncoding? = nil
    ) throws -> ArchiveReadHandle {
        guard let handle = ArchiveReadHandle() else { throw EncryptedArchiveError.archiveUnreadable }
        guard archive_read_support_format_all(handle.raw) == LibArchive.ok,
              archive_read_support_filter_all(handle.raw) == LibArchive.ok
        else { throw EncryptedArchiveError.archiveUnreadable }

        // Declaring the code page has to happen before the file is opened, and it is validated here
        // rather than at the first name: libarchive answers `ARCHIVE_FATAL` for a token it does not
        // know (measured, -30 for a bogus one), so a typo fails as a typo instead of as an archive
        // nobody can read. A token it *does* know but that is wrong for this archive cannot be
        // caught here at all — see ``ArchiveNameEncoding``.
        if let nameEncoding {
            let status = archive_read_set_options(
                handle.raw,
                "hdrcharset=\(nameEncoding.hdrcharset)"
            )
            guard status == LibArchive.ok else { throw EncryptedArchiveError.archiveUnreadable }
        }

        if let passphrase, !passphrase.isEmpty {
            let status = passphrase.withUnsafeCString {
                archive_read_add_passphrase(handle.raw, $0)
            }
            guard status == LibArchive.ok else { throw EncryptedArchiveError.archiveUnreadable }
        }
        guard archive_read_open_filename(handle.raw, path, chunkSize) == LibArchive.ok else {
            throw EncryptedArchiveError.archiveUnreadable
        }
        return handle
    }

    /// Turns libarchive's failure on `handle` into the one thing the user needs to know: retype the
    /// passphrase, or accept that the archive is damaged. See ``LibArchive/isIncorrectPassphrase(_:)``
    /// for why that distinction has to be made from the message.
    static func failure(_ handle: ArchiveReadHandle) -> EncryptedArchiveError {
        LibArchive.isIncorrectPassphrase(handle.raw) ? .incorrectPassphrase : .archiveUnreadable
    }

    /// `nil` when the entry's name is not valid UTF-8 — `archive_entry_pathname_utf8` answers `NULL`
    /// rather than guessing at a code page, and neither does Dirnex.
    /// Internal for the same reason as `openForReading` above.
    static func makeEntry(_ raw: OpaquePointer) -> Entry? {
        guard let namePointer = archive_entry_pathname_utf8(raw) else { return nil }
        let name = String(cString: namePointer)

        let type = archive_entry_filetype(raw)
        let kind: ArchiveSourceItem.Kind
        switch type {
        case LibArchive.directoryType:
            kind = .directory
        case LibArchive.symbolicLinkType:
            guard let target = archive_entry_symlink_utf8(raw) else { return nil }
            kind = .symbolicLink(target: String(cString: target))
        default:
            kind = .regularFile
        }

        return Entry(
            archivePath: name,
            kind: kind,
            byteSize: archive_entry_size(raw),
            permissions: archive_entry_perm(raw),
            modificationDate: Date(timeIntervalSince1970: TimeInterval(archive_entry_mtime(raw))),
            isEncrypted: archive_entry_is_encrypted(raw) != 0
        )
    }
}
