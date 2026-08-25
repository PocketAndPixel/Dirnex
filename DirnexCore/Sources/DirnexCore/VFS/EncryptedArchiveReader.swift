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
    public static func inspect(archiveAt path: String) throws -> Inspection {
        let handle = try openForReading(path, passphrase: nil)
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

    // MARK: - Extraction

    /// Extracts the placeable entries `members` selects into `destinationDirectory`.
    ///
    /// - Parameters:
    ///   - passphrase: Required if ``Inspection/needsPassphrase`` is true; ignored otherwise, so a
    ///     caller may pass one speculatively.
    ///   - members: Which entries to place. Defaults to ``ArchiveMemberFilter/everything``, which is
    ///     what a repack needs; anything extracting *part* of an archive should name what it wants,
    ///     because an entry nobody asked for is stepped over rather than decrypted.
    ///   - onProgress: Called after each chunk with cumulative bytes, measured against the bytes
    ///     `members` selects rather than the archive's.
    ///   - isCancelled: Polled between chunks. Throws `CancellationError`; already-extracted files
    ///     are left in place, since a half-extracted folder the user can see and delete is better
    ///     than a silent rollback of files they may have been waiting for.
    ///
    /// - Throws: ``EncryptedArchiveError/incorrectPassphrase`` when the passphrase does not open it,
    ///   ``EncryptedArchiveError/passphraseRequired`` when one is needed and absent, `VFSError` for a
    ///   destination that cannot be written.
    ///
    /// **A filtered extraction cannot check the passphrase, and that is honest rather than lax.**
    /// Skipping an entry never decrypts it, so a wrong passphrase is silent for every member that
    /// was skipped (probed — `archive_read_data_skip` answers `ARCHIVE_OK` regardless). The members
    /// that *are* placed still fail loudly, which is the only claim this ever made: an extraction
    /// selecting nothing but empty directories succeeds without a correct passphrase because it
    /// genuinely needed none.
    @discardableResult
    public static func extract(
        archiveAt path: String,
        into destinationDirectory: String,
        passphrase: ArchivePassphrase?,
        members: ArchiveMemberFilter = .everything,
        unwrappingHiddenNames: Bool = true,
        onProgress: @escaping (Progress) -> Void = { _ in },
        isCancelled: @escaping () -> Bool = { false }
    ) throws -> ExtractionReport {
        let inspection = try inspect(archiveAt: path)
        if inspection.needsPassphrase {
            guard let passphrase, !passphrase.isEmpty else {
                throw EncryptedArchiveError.passphraseRequired
            }
        }

        // A wrapped archive holds exactly one entry and the requested members are inside it, so the
        // filter belongs to the *inner* extraction — applied out here it would match nothing, place
        // nothing, and report an archive that could not be read. Recognized from the headers, which
        // `inspect` has already read, rather than from what the outer pass happened to place.
        let isWrapped = unwrappingHiddenNames
            && ArchiveNamePrivacy.looksWrapped(inspection.entries.map(\.archivePath))
        let outerMembers: ArchiveMemberFilter = isWrapped ? .everything : members

        let reporting = Reporting(onProgress: onProgress, isCancelled: isCancelled)
        let handle = try openForReading(path, passphrase: passphrase)
        let session = Session(
            handle: handle, root: destinationDirectory,
            totalBytes: inspection.totalByteSize(matching: outerMembers),
            reporting: reporting
        )
        let report = try placeSelectedEntries(
            named: (path as NSString).lastPathComponent, matching: outerMembers, in: session
        )
        guard isWrapped, ArchiveNamePrivacy.looksWrapped(report.extractedPaths) else {
            return report
        }
        return try unwrap(
            at: (destinationDirectory as NSString)
                .appendingPathComponent(ArchiveNamePrivacy.wrappedEntryName),
            into: destinationDirectory,
            members: members,
            refusedSoFar: report.refused,
            reporting: reporting
        )
    }

    /// Walks the open archive once, placing what `members` selects and stepping over the rest.
    ///
    /// Split out of ``extract(archiveAt:into:passphrase:members:unwrappingHiddenNames:onProgress:isCancelled:)``
    /// by concept: everything above it decides *what* this extraction is (passphrase, wrapper,
    /// totals) and this is the pass itself, which is the part with a loop invariant worth reading on
    /// its own. `archiveName` is carried only to name the archive in an entry-name failure.
    private static func placeSelectedEntries(
        named archiveName: String,
        matching members: ArchiveMemberFilter,
        in session: Session
    ) throws -> ExtractionReport {
        let handle = session.handle
        var extracted: [String] = []
        var refused: [Refusal] = []
        var written: Int64 = 0

        while true {
            if session.reporting.isCancelled() { throw CancellationError() }
            var raw: OpaquePointer?
            let status = archive_read_next_header(handle.raw, &raw)
            if status == LibArchive.eof { break }
            guard status == LibArchive.ok || status == LibArchive.warn, let raw else {
                throw failure(handle)
            }
            guard let entry = makeEntry(raw) else {
                throw EncryptedArchiveError.entryNameNotUTF8(archive: archiveName)
            }
            guard members.includes(entryNamed: entry.archivePath) else {
                // Not an error and not a refusal — nobody asked for it. Its data is never decrypted,
                // which is the whole saving: 1.48 s to read a 600 MB encrypted archive against
                // 0.001 s to reach one 6-byte member inside it. The skip is explicit for legibility
                // rather than for speed; `archive_read_next_header` would step over it anyway.
                archive_read_data_skip(handle.raw)
                continue
            }

            switch ArchiveEntryPath.sanitized(entry.archivePath) {
            case let .refused(reason):
                refused.append(Refusal(name: entry.archivePath, reason: reason))
            case let .allowed(relative):
                written = try place(entry, at: relative, alreadyWritten: written, in: session)
                extracted.append(relative)
            }
        }
        return ExtractionReport(extractedPaths: extracted, refused: refused)
    }

    /// Extracts the inner tar an archive packed with hidden names carries, then removes it, so the
    /// user sees the files they were sent rather than a container.
    ///
    /// **Unwrapped exactly once.** The inner extraction passes `unwrappingHiddenNames: false`, which
    /// is what bounds it: an archive whose `Contents.tar` contains another `Contents.tar` — and
    /// nothing stops someone building one, all the way down — would otherwise recurse as deep as it
    /// was nested. One level is what Dirnex writes, so one level is what it undoes; anything beyond
    /// that is left on disk as an ordinary file the user can look at and decide about.
    private static func unwrap(
        at innerPath: String,
        into destinationDirectory: String,
        members: ArchiveMemberFilter,
        refusedSoFar: [Refusal],
        reporting: Reporting
    ) throws -> ExtractionReport {
        defer { try? FileManager.default.removeItem(atPath: innerPath) }
        let inner = try extract(
            archiveAt: innerPath,
            into: destinationDirectory,
            passphrase: nil,
            members: members,
            unwrappingHiddenNames: false,
            onProgress: reporting.onProgress,
            isCancelled: reporting.isCancelled
        )
        return ExtractionReport(
            extractedPaths: inner.extractedPaths,
            refused: refusedSoFar + inner.refused
        )
    }

    // MARK: - libarchive plumbing

    private static func openForReading(
        _ path: String,
        passphrase: ArchivePassphrase?
    ) throws -> ArchiveReadHandle {
        guard let handle = ArchiveReadHandle() else { throw EncryptedArchiveError.archiveUnreadable }
        guard archive_read_support_format_all(handle.raw) == LibArchive.ok,
              archive_read_support_filter_all(handle.raw) == LibArchive.ok
        else { throw EncryptedArchiveError.archiveUnreadable }

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
    private static func makeEntry(_ raw: OpaquePointer) -> Entry? {
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
