import Foundation

/// A `VFSBackend` that browses *and mutates* one remote FTP or FTPS account as a folder tree
/// (PLAN.md §M13). It answers `list`/`stat` and the write primitives — `createDirectory`,
/// `moveItem` (remote `RNFR`/`RNTO`), `removeItem` (recursive, since FTP has no `rm -r`), and byte
/// transfer with resume — so the operation queue drives copies, moves and deletes onto an FTP
/// server just as it does on disk.
///
/// All the logic lives here and is tested: path handling, listing parsing (`FTPListingParser`), the
/// stat interpretation, error mapping, the recursive-delete walk, and the download-vs-upload
/// decision. The only non-hermetic piece — the network — is an injected `FTPTransport`, so the
/// backend is exercised end-to-end against the bytes a real server sent and needs no live server
/// (PLAN.md §2). The app supplies a `Process`-driven transport over the system `curl`.
///
/// The backend's `id` encodes the account (`ftpes://user@host:port`), so a `VFSPath` under it names
/// both which account and which remote path; the app's composite backend routes on that id.
public struct FTPBackend: VFSBackend {
    /// The remote account this backend is connected to — its identity.
    public let location: FTPLocation
    private let transport: any FTPTransport

    public init(location: FTPLocation, transport: any FTPTransport) {
        self.location = location
        self.transport = transport
    }

    public var id: VFSBackendID { .ftp(location) }

    /// Browse, rename, and write — but no Trash, no copy-on-write clone, and no file watching.
    /// Exactly `SFTPBackend`'s set, and it lights up the same M5 degradation paths with no new UI:
    /// with `.write` but not `.trash`, a delete resolves to a *confirmed permanent* delete rather
    /// than failing on a Trash that isn't there; without `.clone`, `CopyEngine` skips the doomed
    /// clone attempt and goes straight to transfer. No `.watch` means no live refresh — an FTP pane
    /// re-lists on focus and on demand, as SFTP does.
    ///
    /// Symbolic links are absent from the write set too, and that is a protocol fact rather than a
    /// choice: FTP has no standard verb that creates one. The default `createSymbolicLink` refusal
    /// is therefore the correct behaviour, and a mirrored tree containing a link reports it.
    public var capabilities: VFSCapabilities { [.read, .write, .rename] }

    public func listDirectory(at path: VFSPath) throws -> [FileEntry] {
        try requireOwnBackend(path)
        let raw = try mapErrors(path) { try transport.listDirectory(path.path) }
        return FTPListingParser.parse(raw).map { entry(from: $0, in: path) }
    }

    /// Stat a single remote item, by finding it in its **parent's** listing.
    ///
    /// FTP gives no other option: there is no `LIST -d`, and unlike `sftp` a directory listing
    /// carries no `.` self row to read the directory's own stat from. The parent listing is also the
    /// *correct* source rather than merely the available one — it reports a symlink as a link, where
    /// anything that resolved the path would follow it (the trap `SFTPBackend.removeItem`
    /// documents).
    ///
    /// The connection root has no parent to be listed in, so it is answered directly: it is a
    /// directory by construction, and the alternative — failing — would make the root unnavigable.
    public func stat(at path: VFSPath) throws -> FileEntry {
        try requireOwnBackend(path)
        guard let parent = path.parent else { return rootEntry(at: path) }
        let raw = try mapErrors(parent) { try transport.listDirectory(parent.path) }
        guard let match = FTPListingParser.parse(raw).first(where: { $0.name == path.lastComponent })
        else {
            throw VFSError.notFound(path)
        }
        return entry(from: match, at: path, name: path.lastComponent)
    }

    /// The connection root as a `FileEntry`. Nothing is asked of the server: a root that could not
    /// be listed will fail at `listDirectory`, with an error that says so.
    private func rootEntry(at path: VFSPath) -> FileEntry {
        FileEntry(
            path: path,
            name: location.host,
            kind: .directory,
            byteSize: 0,
            modificationDate: .distantPast,
            creationDate: .distantPast,
            isHidden: false,
            permissions: 0o755,
            inode: 0,
            symlinkDestination: nil,
            symlinkTargetKind: nil
        )
    }

    // MARK: - Writes

    public func createDirectory(at path: VFSPath) throws {
        try requireOwnBackend(path)
        try mapErrors(path) { try transport.makeDirectory(path.path) }
    }

    /// Rename within this account. A move whose destination lives on a *different* backend is not a
    /// remote rename — throw `EXDEV` so `CopyEngine` falls back to copy-then-delete across
    /// backends, exactly as it does for a cross-volume local move and for SFTP.
    public func moveItem(at source: VFSPath, to destination: VFSPath) throws {
        try requireOwnBackend(source)
        guard destination.backend == id else {
            throw VFSError.io(path: source, code: EXDEV)
        }
        try mapErrors(source) { try transport.rename(source.path, to: destination.path) }
    }

    /// Permanently remove `path`, recursively for directories — FTP has no recursive delete, so a
    /// directory is emptied depth-first before its `RMD`. Each item's kind comes from the listing it
    /// was found in, so a link is removed as a link rather than followed.
    public func removeItem(at path: VFSPath) throws {
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

    /// Remove one already-classified entry: a directory has its children removed first, then the
    /// now-empty directory itself; anything else is removed directly with `DELE`.
    private func removeResolved(_ entry: FileEntry) throws {
        if entry.kind == .directory {
            for child in try listDirectory(at: entry.path) {
                try removeResolved(child)
            }
            try mapErrors(entry.path) { try transport.removeDirectory(entry.path.path) }
        } else {
            try mapErrors(entry.path) { try transport.removeFile(entry.path.path) }
        }
    }

    /// Copy one file's bytes between this account and the local disk — a **download** (remote source
    /// → local destination) or an **upload**. The whole file transfers as one `curl` invocation, so
    /// `progress` is reported once with the byte count and `isCancelled` is honoured at the file
    /// boundary, matching `SFTPBackend`; the queue's pause/cancel still acts between files.
    ///
    /// (Measured 2026-07-25: `curl`'s own progress meter updates about once a second and rounds to
    /// `k`/`M`, so it could drive a bar but not the accounting. Reporting the exact count once per
    /// file keeps FTP and SFTP identical and byte-honest — PLAN.md §7, resolved.)
    ///
    /// **Resume**: when the destination already holds a nonzero *proper prefix* of the source, the
    /// transfer picks up where it left off rather than re-sending — proven live in both directions,
    /// byte-for-byte identical to a whole transfer. `progress` reports only the bytes actually
    /// moved, which `curl` hands back directly.
    public func copyFile(
        at source: VFSPath,
        to destination: VFSPath,
        progress: (Int64) -> Void,
        isCancelled: () -> Bool
    ) throws {
        if isCancelled() { throw CancellationError() }
        let transferred: Int64
        if source.backend == id, destination.backend == .local {
            transferred = try downloadFile(remote: source, toLocal: destination.path)
        } else if source.backend == .local, destination.backend == id {
            transferred = try uploadFile(fromLocal: source.path, remote: destination)
        } else {
            throw VFSError.unsupported(.remoteToRemoteCopy)
        }
        if isCancelled() { throw CancellationError() }
        progress(transferred)
    }

    /// Uploads at or below this size skip resume detection: re-sending a small file is cheaper than
    /// the extra `SIZE` round trip that finding a resumable partial would cost. (Downloads need no
    /// threshold — they gate on the local partial's size, which is free to read.)
    private static let resumeUploadThreshold: Int64 = 1 << 20 // 1 MiB

    /// Download `remote` to `localPath`, resuming from a local partial when one is a proper prefix.
    private func downloadFile(remote source: VFSPath, toLocal localPath: String) throws -> Int64 {
        let existingLocal = localFileSize(localPath)
        // Only when a local partial exists is a remote size worth fetching; `>` short-circuits so a
        // fresh download (the norm) never pays for the round trip.
        let resume = existingLocal > 0 && remoteFileSize(source) > existingLocal
        return try mapErrors(source) {
            try transport.download(source.path, to: localPath, resume: resume)
        }
    }

    /// Upload `localPath` to `remote`, resuming from a remote partial when one is a proper prefix.
    ///
    /// The remote size is checked here rather than left to `curl -C -`, which would query it too:
    /// `curl` cannot distinguish "no partial to resume" from "the file isn't there at all", so
    /// asking first keeps a fresh upload on the plain path.
    private func uploadFile(fromLocal localPath: String, remote destination: VFSPath) throws -> Int64 {
        let sourceSize = localFileSize(localPath)
        let existingRemote = sourceSize > Self.resumeUploadThreshold ? remoteFileSize(destination) : 0
        let resume = existingRemote > 0 && existingRemote < sourceSize
        return try mapErrors(destination) {
            try transport.upload(localPath, to: destination.path, resume: resume)
        }
    }

    /// The size of a local regular file, or 0 when it is absent or unreadable (so a missing
    /// destination reads as "no partial", i.e. a full transfer).
    private func localFileSize(_ path: String) -> Int64 {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: path),
              let size = attributes[.size] as? Int64 else { return 0 }
        return size
    }

    /// The size of a remote file via one `SIZE`, or 0 when it can't be read (missing/unreadable →
    /// no resumable partial). Costs a round trip, so callers gate it behind a cheaper check first.
    private func remoteFileSize(_ path: VFSPath) -> Int64 {
        (try? transport.fileSize(path.path)) ?? 0
    }

    /// Everything on one host shares a single account, so all its jobs serialize (cheap, no I/O — as
    /// `VFSBackend.volumeIdentifier` requires). FTP opens a fresh connection per invocation, so
    /// parallel transfers would multiply logins against a server that commonly caps them.
    public func volumeIdentifier(for path: VFSPath) -> String? {
        "ftp://\(location.host):\(location.port)"
    }

    // MARK: - Mapping

    private func requireOwnBackend(_ path: VFSPath) throws {
        guard path.backend == id else {
            throw VFSError.unsupported(
                .pathOutsideConnection(path: "\(path)", connection: location.descriptor)
            )
        }
    }

    /// Normalize a transport failure onto the shared `VFSError` vocabulary, attaching the `VFSPath`
    /// the transport (which only knows a raw string) couldn't. A `VFSError` thrown from deeper is
    /// passed through unchanged.
    private func mapErrors<T>(_ path: VFSPath, _ body: () throws -> T) throws -> T {
        do {
            return try body()
        } catch let error as FTPTransportError {
            switch error {
            case .notFound:
                throw VFSError.notFound(path)
            case .permissionDenied, .loginDenied:
                throw VFSError.permissionDenied(path)
            // The certificate and TLS-mode cases surface on the connect probe, where the app can
            // act on them (trust the cert, or tell the user to change the security mode); reaching
            // one down here means a server changed behaviour mid-session, which is an I/O failure
            // from this layer's point of view.
            case .certificateUntrusted, .certificateChanged, .unreachable, .timedOut,
                 .tlsNotAvailable, .tlsRequired, .failure:
                throw VFSError.io(path: path, code: EIO)
            }
        } catch let error as FTPQuoteCommand.UnsafePath {
            // A name carrying CR/LF cannot be expressed as an FTP command at all (see
            // `FTPQuoteCommand`). Report it as an invalid argument rather than a network failure.
            _ = error
            throw VFSError.io(path: path, code: EINVAL)
        }
    }

    private func entry(from parsed: FTPListingParser.Entry, in directory: VFSPath) -> FileEntry {
        entry(from: parsed, at: directory.appending(parsed.name), name: parsed.name)
    }

    private func entry(
        from parsed: FTPListingParser.Entry,
        at path: VFSPath,
        name: String
    ) -> FileEntry {
        FileEntry(
            path: path,
            name: name,
            kind: parsed.kind,
            byteSize: parsed.byteSize,
            modificationDate: parsed.modificationDate,
            // FTP exposes no birth time; reuse the modification date, as `ArchiveBackend` and
            // `SFTPBackend` both do.
            creationDate: parsed.modificationDate,
            isHidden: name.hasPrefix("."),
            permissions: parsed.permissions,
            inode: 0,
            symlinkDestination: parsed.symlinkDestination,
            // The target's kind is not knowable without another round trip; report a nominal file
            // so the row renders as a live link rather than a broken one, matching `SFTPBackend`.
            symlinkTargetKind: parsed.kind == .symlink ? .file : nil
        )
    }
}
