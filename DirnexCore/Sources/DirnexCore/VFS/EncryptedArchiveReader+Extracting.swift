import CArchiveShim
import Foundation

/// Performing an extraction — the pass that walks an open archive and decides what is placed.
///
/// Split from `EncryptedArchiveReader` by concept at the ceiling the house rule names: that type
/// answers what an archive *says* (its headers, its entries, whether a passphrase is needed), this
/// one answers what an extraction *does*, and `+Placing` answers where a single entry lands. The
/// three were already one file's three `MARK`s, which is what made the seam obvious.
extension EncryptedArchiveReader {
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
        nameEncoding: ArchiveNameEncoding? = nil,
        unwrappingHiddenNames: Bool = true,
        onProgress: @escaping (Progress) -> Void = { _ in },
        isCancelled: @escaping () -> Bool = { false }
    ) throws -> ExtractionReport {
        let inspection = try inspect(archiveAt: path, nameEncoding: nameEncoding)
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
        // The *inner* extraction of a wrapped archive deliberately takes no encoding: that tar is
        // one Dirnex wrote, so its names are UTF-8 by construction.
        let handle = try openForReading(path, passphrase: passphrase, nameEncoding: nameEncoding)
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
        // Collected rather than applied as they are met: a directory's own mtime moves whenever
        // something is created inside it, so a time set at creation is destroyed by its first
        // child (▸ `place`). Order does not matter here — stamping an item leaves its parent
        // untouched — so this is a plain list rather than a deepest-first walk.
        var directoryTimes: [(path: String, date: Date)] = []

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
                let placement = try place(
                    entry, at: relative, alreadyWritten: written, in: session
                )
                written = placement.bytesWritten
                if let directory = placement.directoryNeedingTime {
                    directoryTimes.append((directory, entry.modificationDate))
                }
                extracted.append(relative)
            }
        }
        for directory in directoryTimes {
            applyModificationTime(directory.date, toItemAt: directory.path)
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
}
