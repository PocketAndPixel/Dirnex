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
public struct SFTPBackend: RemoteTransportBackend {
    /// The remote account this backend is connected to — its identity.
    public let location: SFTPLocation
    /// Internal rather than private so `SFTPBackend+Subtree` can reach it — Swift's `private` does
    /// not cross files (docs/NOTES.md ▸ Lint ceilings and file splitting).
    let transport: any SFTPTransport
    /// How many rows the server-side subtree `find` may print before it is cut off — see
    /// ``SSHFindCommand/defaultRowLimit``, which is where the number and its reasoning live.
    ///
    /// Settable so the cap is *reachable*: it is the one branch of the shortcut that cannot be
    /// exercised at 50 000 rows, and a rule with no test is a rule nobody has watched fail. Left at
    /// its default everywhere in the app.
    public var subtreeRowLimit = SSHFindCommand.defaultRowLimit
    /// What this connection has learned about splitting a download into several exec channels. A
    /// reference held by a value type on purpose: the backend is copied freely, and what it knows
    /// about the *server* must not be copied away with it (``SegmentedDownloadSupport``).
    let segmentation = SegmentedDownloadSupport()
    /// What this connection has learned about carrying a source's mode and times, and what it has
    /// failed to carry so far. A reference held by a value type for exactly the reason
    /// ``segmentation`` is: the backend is copied freely, and a fact about the *server* must not be
    /// copied away with it (``RemoteMetadataSupport``).
    let metadata: RemoteMetadataSupport

    public init(location: SFTPLocation, transport: any SFTPTransport) {
        self.location = location
        self.transport = transport
        // What the *transport* declares, never what SFTP could do in principle. A transport that has
        // not implemented the carry reports `[]`, so every plan asks for nothing and reports the
        // loss — which is the failure direction this milestone chooses (PLAN.md §M25). Assuming
        // `.sftp` here would make such a transport claim a mode it never wrote.
        metadata = RemoteMetadataSupport(offering: transport.metadataCapabilities)
    }

    public var id: VFSBackendID { .sftp(location) }

    public var connectionDescriptor: String { location.descriptor }
    public var writeTransport: any RemoteWriteTransport { transport }

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

    // `createDirectory`, `moveItem` and the recursive `removeItem` are `RemoteTransportBackend`'s —
    // identical to FTP's, since both are the same four transport verbs plus the same depth-first
    // walk. Symbolic links and the byte transfer below are protocol-specific.

    public func createSymbolicLink(at destination: VFSPath, withDestination target: String) throws {
        try requireOwnBackend(destination)
        try mapErrors(destination) { try transport.createSymbolicLink(
            destination.path,
            target: target
        ) }
    }

    /// Copy one file's bytes between this remote account and the local disk — a **download**
    /// (remote source → local destination, via `get`) or an **upload** (local source → remote
    /// destination, via `put`). The whole file transfers as one `sftp` command, and `isCancelled` is
    /// honored inside it as well as at the file boundary (the queue's pause/cancel still acts
    /// between files). A copy that is neither direction — between two accounts, or *within* this
    /// one, since SFTP has no copy verb at all — has no `sftp` expression and is refused here. It
    /// is not refused to the user: a caller holding both ends stages such a copy through this disk
    /// (``RelayCopy``), which is what the app's composite backend does with that pair.
    ///
    /// **`progress` reports as a download runs and only at the end of an upload, and the asymmetry
    /// is `sftp`'s rather than a decision.** A download's destination is a file on this machine, so
    /// watching it grow is exact and free; an upload changes nothing here, and `sftp` — unlike
    /// `curl` — prints no meter a spawned process can read, probed six ways over a 1 GiB transfer
    /// (``SFTPTransport/upload(_:to:resume:progress:isCancelled:)``). Either way the tail below
    /// reports the *remainder* against the measured count, so an upload behaves exactly as it always
    /// did and a download's estimates never decide the total.
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
        try copyFile(
            at: source,
            to: destination,
            expectedSize: nil,
            progress: progress,
            isCancelled: isCancelled
        )
    }

    /// The same copy, told how big the file is (docs/HISTORY.md ▸ After M19).
    ///
    /// **The hint decides whether a download is split**, and it is a hint rather than a probe
    /// because asking would cost a whole connection: `sftp` has no session to reuse, so a remote
    /// `stat` is a fresh TCP connect, key exchange and authentication. Both real callers already
    /// hold the number from the listing they made (`CopyEngine`'s `entry.byteSize`,
    /// `RemoteFileCache`'s entry), so it costs no extra round trip anywhere; with no hint, behaviour
    /// is exactly what it was.
    ///
    /// It is deliberately consulted **only** for the download direction. An upload's shape is
    /// decided by the local file's own size, which this backend reads for itself and which cannot be
    /// stale — and there is no way to split one in any case, since a segment's route here is the
    /// server *reading* a range, and nothing symmetrical exists for writing one.
    public func copyFile(
        at source: VFSPath,
        to destination: VFSPath,
        expectedSize: Int64?,
        progress: (Int64) -> Void,
        isCancelled: () -> Bool
    ) throws {
        try copyFile(
            at: source,
            to: destination,
            hint: CopySourceHint(expectedSize: expectedSize),
            progress: progress,
            isCancelled: isCancelled
        )
    }

    /// The same copy, also carrying the source's mode and modification time (PLAN.md §M25 Slice 2).
    ///
    /// **Both directions are free, and which of them is being served decides what may be carried.**
    /// The plan's capabilities describe the *destination*: an upload lands on the server, so it is
    /// bounded by what this account still honours, while a download lands on this machine, where
    /// `chmod` and `utimes` always work — so a download can carry everything the hint holds even
    /// though the wire under it offers less.
    ///
    /// With no hint the transfer still asks for `-p`, which costs nothing and carries the nine mode
    /// bits and both timestamps on its own; the hint only adds what `-p` cannot express.
    public func copyFile(
        at source: VFSPath,
        to destination: VFSPath,
        hint: CopySourceHint,
        progress: (Int64) -> Void,
        isCancelled: () -> Bool
    ) throws {
        if isCancelled() { throw CancellationError() }
        var tally = TransferProgressTally()
        let streamed = { (delta: Int64) in
            tally.add(delta)
            progress(delta)
        }
        let transferred: Int64
        if source.backend == id, destination.backend == .local {
            transferred = try downloadFile(
                SFTPDownloadRequest(
                    remotePath: source.path,
                    localPath: destination.path,
                    source: source,
                    expectedSize: hint.expectedSize
                ),
                carrying: downloadPlan(for: hint.metadata),
                progress: streamed,
                isCancelled: isCancelled
            )
        } else if source.backend == .local, destination.backend == id {
            transferred = try uploadFile(
                fromLocal: source.path,
                remote: destination,
                carrying: uploadPlan(for: hint.metadata, localSource: source.path),
                progress: streamed,
                isCancelled: isCancelled
            )
        } else {
            throw VFSError.unsupported(.remoteToRemoteCopy)
        }
        if isCancelled() { throw CancellationError() }
        if let remainder = tally.remainder(against: transferred) { progress(remainder) }
    }

    /// What a download may carry: everything the local disk can take, plus `get -p` when this
    /// transport offers it. Nothing is latched here — a local `chmod` failing says nothing about the
    /// server, and there is no verb to stop attempting.
    private func downloadPlan(for hint: RemoteSourceMetadata?) -> RemoteMetadataPlan {
        let capabilities = RemoteMetadataCapabilities.localDestination
            .union(metadata.capabilities.intersection(.preserveFlag))
        return (hint ?? RemoteSourceMetadata(permissions: nil, modificationTime: nil))
            .plan(with: capabilities)
    }

    /// What an upload may carry: whatever this connection still honours, over the local source's own
    /// metadata.
    ///
    /// The hint is read from the local file when the caller did not supply one, because here it is
    /// free — an upload's source is on this machine, so its mode and times are one `lstat`, and
    /// leaving them out would drop a carry for want of a parameter.
    private func uploadPlan(
        for hint: RemoteSourceMetadata?,
        localSource: String
    ) -> RemoteMetadataPlan {
        metadata.plan(for: hint ?? .ofLocalFile(localSource))
    }

    /// The size of a local regular file, or 0 when it is absent or unreadable (so a missing
    /// destination reads as "no partial", i.e. a full transfer).
    func localFileSize(_ path: String) -> Int64 {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: path),
              let size = attributes[.size] as? Int64 else { return 0 }
        return size
    }

    /// The size of a remote file via one `stat`, or 0 when it can't be stat'd (missing/unreadable →
    /// no resumable partial). Costs a round trip, so callers gate it behind a cheaper check first.
    func remoteFileSize(_ path: VFSPath) -> Int64 {
        (try? stat(at: path))?.byteSize ?? 0
    }

    /// Everything on one host shares a single connection, so all its jobs serialize (cheap, no
    /// I/O — as `VFSBackend.volumeIdentifier` requires): two transfers over one SSH channel would
    /// only contend, not parallelize.
    public func volumeIdentifier(for path: VFSPath) -> String? {
        "\(SFTPLocation.scheme)\(location.host):\(location.port)"
    }

    // MARK: - Mapping

    /// Normalize a transport failure onto the shared `VFSError` vocabulary, attaching the
    /// `VFSPath` the transport (which only knows a raw string) couldn't. A `VFSError` thrown from
    /// deeper is passed through unchanged.
    public func mapErrors<T>(_ path: VFSPath, _ body: () throws -> T) throws -> T {
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
            ownerName: parsed.ownerName,
            groupName: parsed.groupName,
            inode: 0,
            symlinkDestination: parsed.symlinkDestination,
            // `sftp` doesn't resolve a symlink's target; report a nominal file target so it renders
            // as a live link rather than a broken one, matching `ArchiveBackend`.
            symlinkTargetKind: kind == .symlink ? .file : nil
        )
    }
}
