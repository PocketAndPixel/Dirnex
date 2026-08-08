import Foundation

/// One thing to put into an archive: where its bytes are now, and what it should be called inside.
///
/// The two paths are separate on purpose. `onDiskPath` is absolute and is what gets opened;
/// `archivePath` is relative, `/`-separated, and is what the recipient sees — so packing
/// `/Users/oleg/docs` yields `docs/…` and never leaks the packer's home directory into the archive.
/// The same split is why `ArchivePacking` passes `bsdtar` a `-C`.
public struct ArchiveSourceItem: Sendable, Hashable {
    /// What the entry is. Only these three go into an archive: a fifo, socket or device node has no
    /// portable representation in a zip, and silently storing one as an empty file would be a lie
    /// the recipient cannot detect.
    public enum Kind: Sendable, Hashable {
        case regularFile
        case directory
        /// Stored as a link, never followed — see ``ArchiveSourceEnumerator``.
        case symbolicLink(target: String)
    }

    /// Absolute path to the bytes on this disk.
    public var onDiskPath: String

    /// The `/`-separated name inside the archive, relative to the archive's root. A macOS filename
    /// cannot contain `/` at the POSIX layer, so joining components with it is unambiguous.
    public var archivePath: String

    public var kind: Kind

    /// Bytes to write. Zero for a directory and for a symlink (whose target is metadata, not data).
    public var byteSize: Int64

    /// The POSIX permission bits, preserved so an extract on another Mac restores the mode.
    public var permissions: mode_t

    public var modificationDate: Date

    /// The file carries `SF_DATALESS` — its bytes are in a cloud, not on this disk.
    public var isDataless: Bool

    public init(
        onDiskPath: String,
        archivePath: String,
        kind: Kind,
        byteSize: Int64,
        permissions: mode_t,
        modificationDate: Date,
        isDataless: Bool
    ) {
        self.onDiskPath = onDiskPath
        self.archivePath = archivePath
        self.kind = kind
        self.byteSize = byteSize
        self.permissions = permissions
        self.modificationDate = modificationDate
        self.isDataless = isDataless
    }
}

/// Walks the selection into a flat, ordered list of ``ArchiveSourceItem``.
///
/// Separated from the writer so the *plan* can be inspected before a byte is written: the total size
/// is what the progress bar needs up front, and the placeholder refusal has to happen before the
/// archive file is created, not halfway through it.
///
/// **Symlinks are stored, not followed.** A symlink pointing at one of its own ancestors is a walk
/// that never ends, and one pointing outside the selection would quietly pack bytes the user did not
/// choose — including, in the worst case, somewhere they would not want sent. `bsdtar` makes the
/// same choice by default.
public enum ArchiveSourceEnumerator {
    /// Every item under `names` within `directory`, depth-first, parents before children.
    ///
    /// Ordering is deterministic (each directory's contents sorted by name) so that packing the same
    /// selection twice produces the same entry order — which is what makes an archive's bytes
    /// comparable across runs and a test's expectations writable.
    ///
    /// - Parameters:
    ///   - directory: The absolute directory `names` are relative to — the pane's current directory.
    ///   - names: Bare names within `directory`. A name that does not exist is skipped rather than
    ///     failing the whole pack: a selection can go stale between the keystroke and the walk.
    ///   - allowDataless: Pass `true` only after the user has agreed to the downloads. By default the
    ///     first `SF_DATALESS` placeholder throws
    ///     ``EncryptedArchiveError/wouldDownloadPlaceholder(name:)`` rather than silently pulling
    ///     files out of iCloud or Google Drive (docs/NOTES.md: one read materializes the whole file
    ///     and blocks).
    ///   - isCancelled: Polled per item; throws `CancellationError` when it fires. A walk over a
    ///     large tree is itself slow enough to need abandoning.
    public static func items(
        inDirectory directory: String,
        names: [String],
        allowDataless: Bool = false,
        isCancelled: @escaping () -> Bool = { false }
    ) throws -> [ArchiveSourceItem] {
        let walk = Walk(allowDataless: allowDataless, isCancelled: isCancelled)
        var collected: [ArchiveSourceItem] = []
        for name in names.sorted() {
            try append(
                name: name,
                onDiskPath: (directory as NSString).appendingPathComponent(name),
                archivePath: name,
                into: &collected,
                walk: walk
            )
        }
        return collected
    }

    /// The two settings that are constant for a whole walk, so the recursion carries one value
    /// instead of threading a growing parameter list through every level.
    private struct Walk {
        let allowDataless: Bool
        let isCancelled: () -> Bool
    }

    /// The total byte count of everything that will actually be written — regular files only.
    /// Directories and symlinks carry no data, so counting them would make a progress bar that
    /// never reaches its own total.
    public static func totalByteSize(of items: [ArchiveSourceItem]) -> Int64 {
        items.reduce(into: 0) { total, item in
            if case .regularFile = item.kind { total += item.byteSize }
        }
    }

    // MARK: - Walking

    private static func append(
        name: String,
        onDiskPath: String,
        archivePath: String,
        into collected: inout [ArchiveSourceItem],
        walk: Walk
    ) throws {
        if walk.isCancelled() { throw CancellationError() }

        // `lstat`, not `stat`: a symlink must be seen as itself. One call answers the type, the
        // size, the mode, the mtime and `SF_DATALESS` — the last of which
        // `FileManager.attributesOfItem` cannot report at all (docs/NOTES.md), which is why the walk
        // is built on the syscall rather than on Foundation.
        var status = stat()
        guard lstat(onDiskPath, &status) == 0 else { return }

        let mode = status.st_mode & S_IFMT
        let dataless = (status.st_flags & UInt32(SF_DATALESS)) != 0

        if mode == S_IFDIR {
            collected.append(
                item(
                    onDiskPath: onDiskPath,
                    archivePath: archivePath,
                    kind: .directory,
                    status: status,
                    isDataless: false
                )
            )
            let children = (try? FileManager.default.contentsOfDirectory(atPath: onDiskPath)) ?? []
            for child in children.sorted() {
                try append(
                    name: child,
                    onDiskPath: (onDiskPath as NSString).appendingPathComponent(child),
                    archivePath: archivePath + "/" + child,
                    into: &collected,
                    walk: walk
                )
            }
            return
        }

        if mode == S_IFLNK {
            guard let target = linkTarget(of: onDiskPath) else { return }
            collected.append(
                item(
                    onDiskPath: onDiskPath,
                    archivePath: archivePath,
                    kind: .symbolicLink(target: target),
                    status: status,
                    isDataless: false
                )
            )
            return
        }

        guard mode == S_IFREG else { return }

        // The guard sits here rather than at the top because a placeholder's *metadata* is real and
        // free to read — it is the byte read that would download. Refusing before the walk knows it
        // has a regular file would also refuse directories, which carry the flag on some providers.
        guard walk.allowDataless || !dataless else {
            throw EncryptedArchiveError.wouldDownloadPlaceholder(name: name)
        }

        collected.append(
            item(
                onDiskPath: onDiskPath,
                archivePath: archivePath,
                kind: .regularFile,
                status: status,
                isDataless: dataless
            )
        )
    }

    /// The size is derived from `kind` rather than passed in: only a regular file has data, and a
    /// directory's `st_size` is its own bookkeeping, which would otherwise be counted into a
    /// progress total that then never completes.
    private static func item(
        onDiskPath: String,
        archivePath: String,
        kind: ArchiveSourceItem.Kind,
        status: stat,
        isDataless: Bool
    ) -> ArchiveSourceItem {
        let byteSize: Int64
        if case .regularFile = kind { byteSize = Int64(status.st_size) } else { byteSize = 0 }
        return ArchiveSourceItem(
            onDiskPath: onDiskPath,
            archivePath: archivePath,
            kind: kind,
            byteSize: byteSize,
            permissions: status.st_mode & ~S_IFMT,
            modificationDate: Date(timeIntervalSince1970: TimeInterval(status.st_mtimespec.tv_sec)),
            isDataless: isDataless
        )
    }

    /// The target of a symlink, or `nil` if it cannot be read or is not valid UTF-8.
    ///
    /// `readlink` does not NUL-terminate, and it truncates silently when the buffer is too small —
    /// so the buffer is `PATH_MAX` and a result that fills it exactly is treated as a failure rather
    /// than stored as a truncated path that would point somewhere else entirely.
    private static func linkTarget(of path: String) -> String? {
        var buffer = [CChar](repeating: 0, count: Int(PATH_MAX))
        let length = readlink(path, &buffer, buffer.count)
        guard length > 0, length < buffer.count else { return nil }
        let bytes = buffer[0..<length].map { UInt8(bitPattern: $0) }
        return String(bytes: bytes, encoding: .utf8)
    }
}
