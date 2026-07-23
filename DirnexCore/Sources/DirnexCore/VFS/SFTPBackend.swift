import Foundation

/// A `VFSBackend` that browses *and mutates* one remote SSH/SFTP account as a folder tree
/// (PLAN.md §M5 "`SFTPBackend`: browse/copy through the standard queue"). It answers `list`/`stat`
/// and the write primitives — `createDirectory`, `moveItem` (remote rename), `removeItem`
/// (recursive, since `sftp` has no `rm -r`), and byte transfer (`copyFile` up/down via the
/// transport's `get`/`put`) — so the operation queue drives copies, moves, and deletes onto a
/// remote just as it does on disk.
///
/// All the logic lives here and is tested: path handling, listing parsing (`SFTPListingParser`),
/// the stat interpretation, error mapping, the recursive-delete walk, and the download-vs-upload
/// decision. The only non-hermetic piece — the network — is an injected `SFTPTransport`, so the
/// backend is exercised end-to-end with a fake and needs no live server (PLAN.md §2). The app
/// supplies a `Process`-driven transport over the system `sftp` tool (the `bsdtar`-style sidestep
/// of a swift-nio-ssh/libssh2 dependency).
///
/// The backend's `id` encodes the account (`sftp://user@host:port`), so a `VFSPath` under it names
/// both which account and which remote path; the app's composite backend routes on that id.
public struct SFTPBackend: VFSBackend {
    /// The remote account this backend is connected to — its identity.
    public let location: SFTPLocation
    private let transport: any SFTPTransport

    public init(location: SFTPLocation, transport: any SFTPTransport) {
        self.location = location
        self.transport = transport
    }

    public var id: VFSBackendID { .sftp(location) }

    /// Browse, rename, and write — but no Trash and no copy-on-write clone. This is exactly the
    /// set the M5 "capability degradation" path was built for (PLAN.md §M5): with `.write` but not
    /// `.trash`, a delete degrades to a *confirmed permanent* delete rather than silently failing
    /// on a missing Trash; without `.clone`, `CopyEngine` skips the doomed clone attempt and goes
    /// straight to chunked transfer. `.watch` is absent too — an SFTP pane has no FSEvents, so it
    /// re-lists explicitly after a mutation instead.
    public var capabilities: VFSCapabilities { [.read, .write, .rename] }

    public func listDirectory(at path: VFSPath) throws -> [FileEntry] {
        try requireOwnBackend(path)
        let raw = try mapErrors(path) { try transport.listDirectory(path.path) }
        return SFTPListingParser.parse(raw)
            .filter { $0.name != "." && $0.name != ".." }
            .map { entry(from: $0, in: path) }
    }

    /// Stat a single remote item. `sftp` has no `ls -d`, so this reads one `ls -la <path>`: when the
    /// result carries a self `.` row, `path` is a directory and that row *is* its stat; otherwise it
    /// is a file (or symlink) whose single row we return. An empty/unmatched result is `notFound`.
    public func stat(at path: VFSPath) throws -> FileEntry {
        try requireOwnBackend(path)
        let raw = try mapErrors(path) { try transport.listDirectory(path.path) }
        let rows = SFTPListingParser.parse(raw)
        if let dot = rows.first(where: { $0.name == "." }) {
            // The `.` row is the directory itself — use its stat but our queried identity/name.
            return entry(from: dot, at: path, name: path.lastComponent, forceDirectory: true)
        }
        guard let match = rows.first(where: { $0.name == path.lastComponent }) else {
            throw VFSError.notFound(path)
        }
        return entry(from: match, at: path, name: path.lastComponent)
    }

    // MARK: - Writes

    public func createDirectory(at path: VFSPath) throws {
        try requireOwnBackend(path)
        try mapErrors(path) { try transport.makeDirectory(path.path) }
    }

    /// Rename within this account. A move whose destination lives on a *different* backend
    /// (download-then-delete, upload-then-delete) is not a remote rename — throw `EXDEV` so
    /// `CopyEngine` falls back to copy-then-delete across backends, exactly as it does for a
    /// cross-volume local move.
    public func moveItem(at source: VFSPath, to destination: VFSPath) throws {
        try requireOwnBackend(source)
        guard destination.backend == id else {
            throw VFSError.io(path: source, code: EXDEV)
        }
        try mapErrors(source) { try transport.rename(source.path, to: destination.path) }
    }

    /// Permanently remove `path`, recursively for directories — `sftp` has no `rm -r`, so a
    /// directory is emptied (depth-first) before its `rmdir`. The item's kind is read from its
    /// **parent listing**, not a `stat` of the path itself: `sftp`'s `ls` follows a symlink, so
    /// statting a link-to-directory would misreport it as a directory and delete the *target's*
    /// contents — a parent listing shows the link as a link, so `rm` removes the link alone.
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

    /// Remove one already-classified entry: a directory has its children removed first (each
    /// child's kind comes from *its* directory listing, so nested links are removed as links),
    /// then the now-empty directory itself; a file or symlink is removed directly.
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

    public func createSymbolicLink(at destination: VFSPath, withDestination target: String) throws {
        try requireOwnBackend(destination)
        try mapErrors(destination) { try transport.createSymbolicLink(
            destination.path,
            target: target
        ) }
    }

    /// Copy one file's bytes between this remote account and the local disk — a **download**
    /// (remote source → local destination, via `get`) or an **upload** (local source → remote
    /// destination, via `put`). The whole file transfers as one `sftp` command, so `progress` is
    /// reported once with the transferred byte count and `isCancelled` is honoured at the file
    /// boundary (the queue's pause/cancel still acts between files). A copy that is neither
    /// direction — remote-to-remote, or between two different accounts — has no `sftp` expression
    /// yet and is refused.
    ///
    /// **Resume**: when the destination already holds a nonzero *proper prefix* of the source
    /// (a partial from an interrupted transfer), the copy picks up where it left off via
    /// `get -a` / `put -a` rather than re-sending the whole file — `sftp` computes the offset from
    /// the existing length. Resume is detected cheaply so the common fresh transfer pays nothing:
    /// a download reads the local partial's size (free); an upload only asks the server for the
    /// remote size when the source is large enough that resuming would actually save work
    /// (`resumeUploadThreshold`), since that check costs a metadata round trip. `progress` reports
    /// only the bytes actually moved (the remainder, when resuming).
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
    /// the extra remote `stat` round trip that finding a resumable partial would cost. (Downloads
    /// need no threshold — they gate resume on the local partial's size, which is free to read.)
    private static let resumeUploadThreshold: Int64 = 1 << 20 // 1 MiB

    /// Download `remote` to `localPath`, resuming from a local partial when one is a proper prefix.
    /// Returns the bytes actually transferred (the whole file, or just the remainder on resume).
    private func downloadFile(remote source: VFSPath, toLocal localPath: String) throws -> Int64 {
        let existingLocal = localFileSize(localPath)
        // Only when a local partial exists is a remote size worth fetching; `>` short-circuits so a
        // fresh download (the norm) never pays for the `stat`.
        let resume = existingLocal > 0 && remoteFileSize(source) > existingLocal
        let finalSize = try mapErrors(source) {
            try transport.download(source.path, to: localPath, resume: resume)
        }
        return resume ? max(0, finalSize - existingLocal) : finalSize
    }

    /// Upload `localPath` to `remote`, resuming from a remote partial when one is a proper prefix.
    /// Returns the bytes actually transferred (the whole file, or just the remainder on resume).
    private func uploadFile(fromLocal localPath: String, remote destination: VFSPath) throws -> Int64 {
        let sourceSize = localFileSize(localPath)
        // The remote size costs a round trip, so only look when resuming could pay off (a big file).
        let existingRemote = sourceSize > Self.resumeUploadThreshold ? remoteFileSize(destination) : 0
        let resume = existingRemote > 0 && existingRemote < sourceSize
        let finalSize = try mapErrors(destination) {
            try transport.upload(localPath, to: destination.path, resume: resume)
        }
        return resume ? max(0, finalSize - existingRemote) : finalSize
    }

    /// The size of a local regular file, or 0 when it is absent or unreadable (so a missing
    /// destination reads as "no partial", i.e. a full transfer).
    private func localFileSize(_ path: String) -> Int64 {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: path),
              let size = attributes[.size] as? Int64 else { return 0 }
        return size
    }

    /// The size of a remote file via one `stat`, or 0 when it can't be stat'd (missing/unreadable →
    /// no resumable partial). Costs a round trip, so callers gate it behind a cheaper check first.
    private func remoteFileSize(_ path: VFSPath) -> Int64 {
        (try? stat(at: path))?.byteSize ?? 0
    }

    /// Everything on one host shares a single connection, so all its jobs serialize (cheap, no
    /// I/O — as `VFSBackend.volumeIdentifier` requires): two transfers over one SSH channel would
    /// only contend, not parallelize.
    public func volumeIdentifier(for path: VFSPath) -> String? {
        "\(SFTPLocation.scheme)\(location.host):\(location.port)"
    }

    // MARK: - Mapping

    private func requireOwnBackend(_ path: VFSPath) throws {
        guard path.backend == id else {
            throw VFSError.unsupported(
                .pathOutsideConnection(path: "\(path)", connection: location.descriptor)
            )
        }
    }

    /// Normalize a transport failure onto the shared `VFSError` vocabulary, attaching the
    /// `VFSPath` the transport (which only knows a raw string) couldn't. A `VFSError` thrown from
    /// deeper is passed through unchanged.
    private func mapErrors<T>(_ path: VFSPath, _ body: () throws -> T) throws -> T {
        do {
            return try body()
        } catch let error as SFTPTransportError {
            switch error {
            case .notFound: throw VFSError.notFound(path)
            case .permissionDenied: throw VFSError.permissionDenied(path)
            // A changed host key surfaces on the connect probe (handled by the app's re-trust flow),
            // not here; if one ever reaches a deeper op it maps to a generic I/O error like .failure.
            case .hostKeyChanged, .failure: throw VFSError.io(path: path, code: EIO)
            }
        }
    }

    private func entry(from parsed: SFTPListingParser.Entry, in directory: VFSPath) -> FileEntry {
        entry(from: parsed, at: directory.appending(parsed.name), name: parsed.name)
    }

    private func entry(
        from parsed: SFTPListingParser.Entry,
        at path: VFSPath,
        name: String,
        forceDirectory: Bool = false
    ) -> FileEntry {
        let kind: FileEntry.Kind = forceDirectory ? .directory : parsed.kind
        return FileEntry(
            path: path,
            name: name,
            kind: kind,
            byteSize: parsed.byteSize,
            modificationDate: parsed.modificationDate,
            // `ls`/SFTP exposes no birth time; reuse the modification date, as `ArchiveBackend` does.
            creationDate: parsed.modificationDate,
            isHidden: name.hasPrefix("."),
            permissions: parsed.permissions,
            inode: 0,
            symlinkDestination: parsed.symlinkDestination,
            // `sftp` doesn't resolve a symlink's target; report a nominal file target so it renders
            // as a live link rather than a broken one, matching `ArchiveBackend`.
            symlinkTargetKind: kind == .symlink ? .file : nil
        )
    }
}
