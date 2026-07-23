import Foundation

/// A read-only `VFSBackend` that browses one archive's contents as a folder tree
/// (PLAN.md §M4 "browse zip/tar/tgz as folders" — cashing in the VFS abstraction).
///
/// It answers `list`/`stat` purely from an in-memory `ArchiveTOC`, so navigating inside an
/// archive never re-reads it: the app's `ArchiveMounter` runs `bsdtar` once, off-main, to
/// build the TOC and construct the backend. Extraction (Quick Look inside, F5 copy-out) and
/// packing are a later M4 pass — hence `capabilities == .read` and the write primitives
/// stay at their `.unsupported` defaults, which the panel greys out (§M5 "capability
/// degradation").
///
/// The backend's `id` encodes the archive's on-disk path, so a `VFSPath` under it identifies
/// both the archive and the inner entry; the composite backend routes on that id.
public struct ArchiveBackend: VFSBackend {
    /// The archive's real location on disk — its identity, and the anchor the app uses to
    /// exit back to the containing folder.
    public let archiveOnDiskPath: String
    private let toc: ArchiveTOC

    public init(archiveOnDiskPath: String, toc: ArchiveTOC) {
        self.archiveOnDiskPath = archiveOnDiskPath
        self.toc = toc
    }

    public var id: VFSBackendID { .archive(forArchiveAt: archiveOnDiskPath) }

    /// Read-only for now — writing inside an archive (add/delete) is the next M4 item.
    public var capabilities: VFSCapabilities { .read }

    public func listDirectory(at path: VFSPath) throws -> [FileEntry] {
        try requireOwnBackend(path)
        guard toc.isDirectory(atInnerPath: path.path) else {
            throw toc.entry(atInnerPath: path.path) == nil
                ? VFSError.notFound(path)
                : VFSError.notADirectory(path)
        }
        return toc.children(inDirectory: path.path).map { fileEntry(from: $0, in: path) }
    }

    public func stat(at path: VFSPath) throws -> FileEntry {
        try requireOwnBackend(path)
        guard let entry = toc.entry(atInnerPath: path.path) else { throw VFSError.notFound(path) }
        return fileEntry(from: entry, at: path)
    }

    // MARK: - Mapping

    private func requireOwnBackend(_ path: VFSPath) throws {
        guard path.backend == id else {
            throw VFSError.unsupported(
                .pathOutsideArchive(path: "\(path)", archive: archiveOnDiskPath)
            )
        }
    }

    private func fileEntry(from entry: ArchiveTOC.Entry, in directory: VFSPath) -> FileEntry {
        fileEntry(from: entry, at: directory.appending(entry.name))
    }

    private func fileEntry(from entry: ArchiveTOC.Entry, at path: VFSPath) -> FileEntry {
        FileEntry(
            path: path,
            name: entry.name,
            kind: entry.kind,
            byteSize: entry.byteSize,
            modificationDate: entry.modificationDate,
            creationDate: entry.modificationDate,
            isHidden: entry.name.hasPrefix("."),
            permissions: entry.kind == .directory ? 0o755 : 0o644,
            inode: 0,
            symlinkDestination: entry.symlinkDestination,
            // A symlink inside a browsed archive isn't resolved (its target may be another
            // archive member); report a nominal file target so it renders as a live link.
            symlinkTargetKind: entry.kind == .symlink ? .file : nil
        )
    }
}
