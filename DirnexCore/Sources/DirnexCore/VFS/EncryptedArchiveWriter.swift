import CArchiveShim
import Foundation

/// Writes a zip archive, optionally AES-256 encrypted, through the system libarchive.
///
/// This is the one archive path in Dirnex that does **not** shell out to `bsdtar`, and the reason is
/// the passphrase: `bsdtar` accepts it only in argv, where any `ps` can read it, and its interactive
/// fallback loops forever on a non-tty stdin. `archive_write_set_passphrase` takes a buffer
/// `ArchivePassphrase` owns and wipes. `CArchiveShim/include/shim.h` argues the exception at length.
///
/// Three properties the CLI could not give us came along with it, and they are why the *unencrypted*
/// path could reasonably move here later: byte-accurate progress (libarchive tells us nothing, but
/// we are the ones feeding it, so we count), real cancellation between chunks rather than a signal,
/// and errors as return codes instead of scraped English.
///
/// **The archive is built under a temporary name and renamed into place.** PLAN.md §6 requires it
/// for archive *rewrites*; it matters just as much for a create, because a cancelled or failed pack
/// otherwise leaves a plausible-looking archive that opens and is missing most of its contents.
public enum EncryptedArchiveWriter {
    /// How far along the pack is. Byte counts cover regular-file data only — directories and
    /// symlinks carry none, so counting them would give a bar that never fills.
    public struct Progress: Sendable, Equatable {
        public let bytesWritten: Int64
        public let totalBytes: Int64
        public let itemsWritten: Int
        public let totalItems: Int
        /// The archive-relative name currently being written, for a "Compressing …" line.
        public let currentName: String
    }

    /// The read size. Matches `ChecksumEngine.chunkSize` — the M14 probe measured throughput flat
    /// between 64 KiB and 4 MiB, so there is nothing here to tune either.
    public static let chunkSize = 128 * 1024

    /// Packs `items` into a new archive at `destinationPath`.
    ///
    /// - Parameters:
    ///   - items: From ``ArchiveSourceEnumerator``, which has already applied the placeholder rule
    ///     and fixed the order.
    ///   - destinationPath: Absolute. Overwritten only on success, by an atomic rename.
    ///   - encryption: `.none` writes an ordinary zip through the same path, so there is one writer
    ///     rather than two that can drift.
    ///   - passphrase: Required when `encryption` is not `.none`, refused when it is empty, and
    ///     ignored otherwise.
    ///   - level: The same three-step dial the pack sheet already offers.
    ///   - onProgress: Called after every chunk and at each entry boundary.
    ///   - isCancelled: Polled between chunks and between entries. Throws `CancellationError`, and
    ///     the partial archive is removed before it propagates.
    ///
    /// - Throws: ``EncryptedArchiveError`` for the guards and for libarchive's own failures;
    ///   `VFSError` for a source file that cannot be read; `CancellationError` when abandoned.
    public static func write(
        items: [ArchiveSourceItem],
        toArchiveAt destinationPath: String,
        encryption: ArchiveEncryption,
        passphrase: ArchivePassphrase?,
        namePrivacy: ArchiveNamePrivacy = .visible,
        level: ArchivePacking.CompressionLevel = .normal,
        onProgress: @escaping (Progress) -> Void = { _ in },
        isCancelled: @escaping () -> Bool = { false }
    ) throws {
        guard !items.isEmpty else { throw EncryptedArchiveError.nothingToArchive }
        if encryption.isEncrypted {
            guard let passphrase, !passphrase.isEmpty else {
                throw EncryptedArchiveError.emptyPassphrase
            }
        }

        let settings = Settings(
            encryption: encryption,
            passphrase: encryption.isEncrypted ? passphrase : nil,
            level: level
        )
        let temporaryPath = temporaryPath(besideArchiveAt: destinationPath)
        do {
            switch namePrivacy {
            case .visible:
                try writeArchive(
                    items: items, atPath: temporaryPath, settings: settings,
                    onProgress: onProgress, isCancelled: isCancelled
                )
            case .hidden:
                try writeWrapped(
                    items: items, atPath: temporaryPath, settings: settings,
                    onProgress: onProgress, isCancelled: isCancelled
                )
            }
        } catch {
            try? FileManager.default.removeItem(atPath: temporaryPath)
            throw error
        }

        do {
            // `replaceItemAt` handles both "nothing there" and "overwrite" and is atomic on the same
            // volume, which the temporary is guaranteed to be on because it was created beside the
            // destination.
            _ = try FileManager.default.replaceItemAt(
                URL(fileURLWithPath: destinationPath),
                withItemAt: URL(fileURLWithPath: temporaryPath)
            )
        } catch {
            try? FileManager.default.removeItem(atPath: temporaryPath)
            throw EncryptedArchiveError.archiveNotWritable
        }
    }

    // MARK: - The libarchive session

    /// What stays constant for a whole pack: the open handle, the totals the progress values are
    /// measured against, and the two callbacks. Bundled so the entry loop passes one value rather
    /// than threading six unchanging arguments down every level.
    private struct Session {
        let handle: ArchiveWriteHandle
        let totalBytes: Int64
        let totalItems: Int
        let onProgress: (Progress) -> Void
        let isCancelled: () -> Bool
    }

    /// The container an archive is written in.
    ///
    /// Only two exist because only two are needed: the zip Dirnex produces, and the tar that goes
    /// *inside* one when file names are being hidden. This is not the pack sheet's format list —
    /// `ArchivePacking.Format` still owns that, and every other format still goes through `bsdtar`.
    enum Container {
        case zip
        case tar
    }

    /// The parameters of one pack, as chosen by the caller.
    struct Settings {
        let encryption: ArchiveEncryption
        let passphrase: ArchivePassphrase?
        let level: ArchivePacking.CompressionLevel
        var container: Container = .zip
    }

    static func writeArchive(
        items: [ArchiveSourceItem],
        atPath path: String,
        settings: Settings,
        onProgress: @escaping (Progress) -> Void,
        isCancelled: @escaping () -> Bool
    ) throws {
        let encryption = settings.encryption
        let passphrase = settings.passphrase
        guard let handle = ArchiveWriteHandle() else {
            throw EncryptedArchiveError.archiveNotWritable
        }
        let format = switch settings.container {
        case .zip: archive_write_set_format_zip(handle.raw)
        case .tar: archive_write_set_format_pax_restricted(handle.raw)
        }
        guard format == LibArchive.ok else {
            throw EncryptedArchiveError.archiveNotWritable
        }
        if let options = writeOptions(settings) {
            guard archive_write_set_options(handle.raw, options) == LibArchive.ok else {
                throw EncryptedArchiveError.archiveNotWritable
            }
        }
        if let passphrase {
            let status = passphrase.withUnsafeCString { archive_write_set_passphrase(handle.raw, $0) }
            guard status == LibArchive.ok else { throw EncryptedArchiveError.archiveNotWritable }
        }
        guard archive_write_open_filename(handle.raw, path) == LibArchive.ok else {
            throw EncryptedArchiveError.archiveNotWritable
        }

        let totalBytes = ArchiveSourceEnumerator.totalByteSize(of: items)
        let session = Session(
            handle: handle, totalBytes: totalBytes, totalItems: items.count,
            onProgress: onProgress, isCancelled: isCancelled
        )
        var written: Int64 = 0
        for (index, item) in items.enumerated() {
            if isCancelled() { throw CancellationError() }
            onProgress(Progress(
                bytesWritten: written, totalBytes: totalBytes,
                itemsWritten: index, totalItems: items.count, currentName: item.archivePath
            ))
            written = try writeEntry(item, at: index, alreadyWritten: written, in: session)
        }

        // Only `close` flushes the central directory. A handle that is merely freed leaves a file
        // that is not an archive at all, which is why this return value is checked rather than
        // trusted to the deinit.
        guard archive_write_close(handle.raw) == LibArchive.ok else {
            throw EncryptedArchiveError.archiveNotWritable
        }
        onProgress(Progress(
            bytesWritten: written, totalBytes: totalBytes,
            itemsWritten: items.count, totalItems: items.count, currentName: ""
        ))
    }

    /// Options for `archive_write_set_options`, or `nil` when there are none.
    ///
    /// Written **unprefixed**, for the reason `ArchivePacking` documents: a module prefix has to name
    /// the writer actually running, so `zip:` hardcoded here breaks the moment the format changes.
    ///
    /// A `.tar` container gets **nothing**, and that is a hard requirement rather than an
    /// optimization: plain tar compresses nothing, and handing its writer `compression-level` is not
    /// ignored — libarchive fails the call with "Undefined option" and no archive is produced
    /// (docs/NOTES.md, measured against `bsdtar`). The option has to be withheld, not passed and
    /// hoped over.
    private static func writeOptions(_ settings: Settings) -> String? {
        guard settings.container == .zip else { return nil }
        var options: [String] = []
        if let value = settings.level.optionValue { options.append("compression-level=\(value)") }
        if let option = settings.encryption.writeOption { options.append(option) }
        return options.isEmpty ? nil : options.joined(separator: ",")
    }

    // MARK: - One entry

    /// Writes one item's header and, for a regular file, its bytes. Returns the new cumulative count.
    private static func writeEntry(
        _ item: ArchiveSourceItem,
        at itemIndex: Int,
        alreadyWritten: Int64,
        in session: Session
    ) throws -> Int64 {
        let handle = session.handle
        guard case .regularFile = item.kind else {
            try writeHeader(for: item, declaringSize: 0, to: handle)
            _ = archive_write_finish_entry(handle.raw)
            return alreadyWritten
        }

        // Open first, then take the size from the *open descriptor*. Sizing from the walk's `lstat`
        // instead would race: the file can change between the walk and here, and libarchive must be
        // told a length it will actually receive.
        let descriptor = open(item.onDiskPath, O_RDONLY)
        guard descriptor >= 0 else {
            throw VFSError.fromErrno(errno, path: .local(item.onDiskPath))
        }
        defer { close(descriptor) }

        var status = stat()
        guard fstat(descriptor, &status) == 0 else {
            throw VFSError.fromErrno(errno, path: .local(item.onDiskPath))
        }
        let declaredSize = Int64(status.st_size)
        try writeHeader(for: item, declaringSize: declaredSize, to: handle)

        var written = alreadyWritten
        var remaining = declaredSize
        var buffer = [UInt8](repeating: 0, count: chunkSize)
        while remaining > 0 {
            if session.isCancelled() { throw CancellationError() }
            let want = Int(min(Int64(chunkSize), remaining))
            let got = buffer.withUnsafeMutableBytes { read(descriptor, $0.baseAddress, want) }
            guard got > 0 else {
                // Short read before the declared length: the file was truncated under us. Left
                // unreported, libarchive would pad the rest with NULs and produce a valid archive
                // holding a silently corrupted file.
                throw EncryptedArchiveError.sourceChangedDuringPacking(name: item.archivePath)
            }
            let put = buffer.withUnsafeBytes { archive_write_data(handle.raw, $0.baseAddress, got) }
            guard put == got else { throw EncryptedArchiveError.archiveNotWritable }
            remaining -= Int64(got)
            written += Int64(got)
            session.onProgress(Progress(
                bytesWritten: written, totalBytes: session.totalBytes,
                itemsWritten: itemIndex, totalItems: session.totalItems,
                currentName: item.archivePath
            ))
        }

        guard archive_write_finish_entry(handle.raw) == LibArchive.ok else {
            throw EncryptedArchiveError.archiveNotWritable
        }
        return written
    }

    private static func writeHeader(
        for item: ArchiveSourceItem,
        declaringSize size: Int64,
        to handle: ArchiveWriteHandle
    ) throws {
        guard let entry = archive_entry_new() else {
            throw EncryptedArchiveError.archiveNotWritable
        }
        defer { archive_entry_free(entry) }

        archive_entry_set_pathname_utf8(entry, item.archivePath)
        archive_entry_set_perm(entry, item.permissions)
        archive_entry_set_mtime(entry, time_t(item.modificationDate.timeIntervalSince1970), 0)

        switch item.kind {
        case .regularFile:
            archive_entry_set_filetype(entry, LibArchive.regularFileType)
            archive_entry_set_size(entry, size)
        case .directory:
            archive_entry_set_filetype(entry, LibArchive.directoryType)
            archive_entry_set_size(entry, 0)
        case let .symbolicLink(target):
            archive_entry_set_filetype(entry, LibArchive.symbolicLinkType)
            archive_entry_set_symlink_utf8(entry, target)
            archive_entry_set_size(entry, 0)
        }

        // `ARCHIVE_WARN` is not failure: libarchive reports it for a header it stored with a
        // reservation (an mtime outside the zip epoch, say) and keeps the handle usable. Treating it
        // as an error would abandon whole archives over a 1979 timestamp.
        let status = archive_write_header(handle.raw, entry)
        guard status == LibArchive.ok || status == LibArchive.warn else {
            throw EncryptedArchiveError.archiveNotWritable
        }
    }

    // MARK: - Temporary file

    /// A hidden sibling of the destination, so the rename that follows stays on one volume.
    ///
    /// Internal rather than private: the wrapping path in `EncryptedArchiveWriter+Wrapping.swift`
    /// needs a second one for its inner tar, and Swift's `private` does not cross files.
    static func temporaryPath(besideArchiveAt destinationPath: String) -> String {
        let directory = (destinationPath as NSString).deletingLastPathComponent
        let name = ".dirnex-pack-\(UUID().uuidString).tmp"
        return (directory as NSString).appendingPathComponent(name)
    }
}
