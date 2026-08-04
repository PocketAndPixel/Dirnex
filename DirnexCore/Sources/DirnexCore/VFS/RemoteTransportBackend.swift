import Foundation

/// The four write verbs a remote file transport offers, whatever wire protocol it speaks.
///
/// `FTPTransport` and `SFTPTransport` both refine this: `curl`'s `MKD`/`RNFR`+`RNTO`/`DELE`/`RMD`
/// and `sftp`'s `mkdir`/`rename`/`rm`/`rmdir` are the same four operations under different names,
/// which is what lets `RemoteTransportBackend` express the writes once for both.
public protocol RemoteWriteTransport: Sendable {
    /// Create one directory. The parent must already exist — neither protocol has a `mkdir -p`.
    func makeDirectory(_ remotePath: String) throws

    /// Rename (move) within the account.
    func rename(_ source: String, to destination: String) throws

    /// Remove one file or symlink. Never a directory.
    func removeFile(_ remotePath: String) throws

    /// Remove one **empty** directory. Neither protocol has a recursive delete.
    func removeDirectory(_ remotePath: String) throws
}

/// A `VFSBackend` that mutates one remote account through a ``RemoteWriteTransport``.
///
/// FTP and SFTP are different protocols with different error vocabularies and different listing
/// dialects, but their *write* half is the same shape: check the path belongs to this connection,
/// hand the raw string to the transport, and map whatever it throws onto `VFSError`. Only the last
/// of those differs, so it stays a requirement (``mapErrors(_:_:)``) while the rest lives here.
///
/// The recursive delete is the part that most wants one home. Neither protocol has `rm -r`, so a
/// directory has to be walked depth-first — and each item's kind must be read from the **listing it
/// was found in** rather than from a `stat`, because `sftp`'s `ls` follows symlinks and would report
/// a link-to-directory as a directory, deleting the *target's* contents. That rule was written twice
/// and is now written once.
public protocol RemoteTransportBackend: VFSBackend {
    /// How this connection names itself in an error the user reads (`user@host:port`).
    var connectionDescriptor: String { get }

    /// The transport the shared write verbs are issued through.
    var writeTransport: any RemoteWriteTransport { get }

    /// Normalize a transport failure onto the shared `VFSError` vocabulary, attaching the `VFSPath`
    /// the transport (which only knows a raw string) couldn't. Each protocol's transport throws its
    /// own error type, so this is the one piece that cannot be shared.
    func mapErrors<T>(_ path: VFSPath, _ body: () throws -> T) throws -> T
}

public extension RemoteTransportBackend {
    /// Refuse a path belonging to another connection before it reaches the wire — a path under a
    /// *different* account would otherwise be sent to this one as a raw string and act on whatever
    /// happens to live there.
    func requireOwnBackend(_ path: VFSPath) throws {
        guard path.backend == id else {
            throw VFSError.unsupported(
                .pathOutsideConnection(path: "\(path)", connection: connectionDescriptor)
            )
        }
    }

    func createDirectory(at path: VFSPath) throws {
        try requireOwnBackend(path)
        try mapErrors(path) { try writeTransport.makeDirectory(path.path) }
    }

    /// Rename within this account. A move whose destination lives on a *different* backend
    /// (download-then-delete, upload-then-delete) is not a remote rename — throw `EXDEV` so
    /// `CopyEngine` falls back to copy-then-delete across backends, exactly as it does for a
    /// cross-volume local move.
    func moveItem(at source: VFSPath, to destination: VFSPath) throws {
        try requireOwnBackend(source)
        guard destination.backend == id else {
            throw VFSError.io(path: source, code: EXDEV)
        }
        try mapErrors(source) { try writeTransport.rename(source.path, to: destination.path) }
    }

    /// Permanently remove `path`, recursively for directories — neither protocol has `rm -r`, so a
    /// directory is emptied depth-first before its `rmdir`/`RMD`.
    ///
    /// The item's kind is read from its **parent listing**, not a `stat` of the path itself: see the
    /// type's note — statting would follow a symlink and delete the target's contents.
    func removeItem(at path: VFSPath) throws {
        try requireOwnBackend(path)
        guard let parent = path.parent else {
            throw VFSError.unsupported(.deleteConnectionRoot)
        }
        let siblings = try listDirectory(at: parent)
        guard let entry = siblings.first(where: { $0.name == path.lastComponent }) else {
            throw VFSError.notFound(path)
        }
        try removeResolved(entry)
    }

    /// Remove one already-classified entry: a directory has its children removed first (each child's
    /// kind comes from *its* directory listing, so nested links are removed as links), then the
    /// now-empty directory itself; a file or symlink is removed directly.
    private func removeResolved(_ entry: FileEntry) throws {
        if entry.kind == .directory {
            for child in try listDirectory(at: entry.path) {
                try removeResolved(child)
            }
            try mapErrors(entry.path) { try writeTransport.removeDirectory(entry.path.path) }
        } else {
            try mapErrors(entry.path) { try writeTransport.removeFile(entry.path.path) }
        }
    }
}
