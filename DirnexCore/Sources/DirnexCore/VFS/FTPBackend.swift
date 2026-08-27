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
public struct FTPBackend: RemoteTransportBackend {
    /// The remote account this backend is connected to — its identity.
    public let location: FTPLocation
    // Internal rather than private: the segmented download lives in `FTPBackend+Segmented.swift`,
    // and Swift's `private` does not cross files (docs/NOTES.md ▸ file splitting).
    let transport: any FTPTransport
    /// What this connection has learned about splitting a download into several logins. A reference
    /// held by a value type on purpose: the backend is copied freely, and what it knows about the
    /// *server* must not be copied away with it (``SegmentedDownloadSupport``).
    let segmentation = SegmentedDownloadSupport()

    public init(location: FTPLocation, transport: any FTPTransport) {
        self.location = location
        self.transport = transport
    }

    public var id: VFSBackendID { .ftp(location) }

    public var connectionDescriptor: String { location.descriptor }
    public var writeTransport: any RemoteWriteTransport { transport }

    /// Browse, rename, and write — but no Trash, no copy-on-write clone, and no file watching.
    /// Exactly `SFTPBackend`'s set, and it lights up the same M5 degradation paths with no new UI:
    /// with `.write` but not `.trash`, a delete resolves to a *confirmed permanent* delete rather
    /// than failing on a Trash that isn't there; without `.clone`, `CopyEngine` skips the doomed
    /// clone attempt and goes straight to transfer. No `.watch` means no live refresh — an FTP pane
    /// re-lists on focus and on demand, as SFTP does.
    ///
    /// Symbolic links are absent from the write set too, and that is a protocol fact rather than a
    /// choice: FTP has no standard verb that creates one. The default `createSymbolicLink` refusal
    /// is therefore the correct behavior, and a mirrored tree containing a link reports it.
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
            modificationDate: FileEntry.unknownDate,
            creationDate: FileEntry.unknownDate,
            isHidden: false,
            // Nothing is asked of the server for a root, so nothing about it has been reported —
            // including its mode. `0o755` here was a guess with no row behind it.
            permissions: nil,
            inode: 0,
            symlinkDestination: nil,
            symlinkTargetKind: nil
        )
    }

    // MARK: - Writes

    // `createDirectory`, `moveItem` and the recursive `removeItem` are `RemoteTransportBackend`'s —
    // identical to SFTP's, since both are the same four transport verbs plus the same depth-first
    // walk. Only the byte transfer below is protocol-specific.

    /// Copy one file's bytes between this account and the local disk — a **download** (remote source
    /// → local destination) or an **upload**. Any other pair of ends is refused: FTP has no copy
    /// verb, so a duplicate within one account is as unexpressible here as one between two, and a
    /// caller holding both ends stages it through this disk instead (``RelayCopy``). The whole file
    /// transfers as one `curl` invocation, and
    /// `isCancelled` is honored at the file boundary as well as inside the transfer; the queue's
    /// pause/cancel still acts between files.
    ///
    /// **`progress` reports as the bytes move, and still settles on the exact count.** The two are
    /// separate claims because what arrives mid-transfer is an estimate: a download watches its own
    /// destination file grow (exact, and free), while an upload has only `curl`'s percentage meter
    /// at one-per-cent resolution. Either way the tail below reports the *remainder* against the
    /// figure `curl` measured, so the number the job ends on is never a sum of estimates.
    ///
    /// (PLAN.md §7 settled this the other way in 2026-07-25 — one exact count per file, on the
    /// ground that the meter is too coarse to account with. That was right about the accounting and
    /// wrong about the silence: a *slow* transfer then reports nothing at all until it is over,
    /// measured 2026-08-16 as 8 seconds of a motionless bar for an 8 MB upload, and 99 seconds on
    /// the S3 twin that reported it as the copy not working. The estimate drives the bar; the exact
    /// figure still decides the total.)
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
    /// **The hint decides whether a download is split**, and it is a hint rather than a probe for a
    /// measured reason: FTP's own `SIZE` is a round trip, and paying it on every small file to
    /// answer a question that only matters above 16 MiB would slow the common case to speed up the
    /// rare one. Both real callers already hold the number from the listing they made
    /// (`CopyEngine`'s `entry.byteSize`, `RemoteFileCache`'s entry), so it costs no extra request
    /// anywhere; with no hint, behaviour is exactly what it was.
    ///
    /// It is deliberately consulted **only** for the download direction. An upload's shape is
    /// decided by the local file's own size, which this backend reads for itself and which cannot be
    /// stale.
    public func copyFile(
        at source: VFSPath,
        to destination: VFSPath,
        expectedSize: Int64?,
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
                FTPDownloadRequest(
                    remotePath: source.path,
                    localPath: destination.path,
                    source: source,
                    expectedSize: expectedSize
                ),
                progress: streamed,
                isCancelled: isCancelled
            )
        } else if source.backend == .local, destination.backend == id {
            transferred = try uploadFile(
                fromLocal: source.path,
                remote: destination,
                progress: streamed,
                isCancelled: isCancelled
            )
        } else {
            throw VFSError.unsupported(.remoteToRemoteCopy)
        }
        if isCancelled() { throw CancellationError() }
        if let remainder = tally.remainder(against: transferred) { progress(remainder) }
    }

    /// Uploads at or below this size skip resume detection: re-sending a small file is cheaper than
    /// the extra `SIZE` round trip that finding a resumable partial would cost. (Downloads need no
    /// threshold — they gate on the local partial's size, which is free to read.)
    private static let resumeUploadThreshold: Int64 = 1 << 20 // 1 MiB

    /// Download to `localPath` — in several ranges at once when that is worth doing, in one stream
    /// when it is not.
    ///
    /// The fork has three conditions and each excludes a case the segmented path cannot serve. A
    /// **partial already on disk** takes the resuming route untouched, because segments are fetched
    /// into files of their own and have nothing to continue from; no **size hint** means no plan,
    /// since asking for one would cost the `SIZE` round trip this avoids; and a connection that has
    /// already shown it **will not serve a split download** is not asked again, which on a server
    /// capping concurrent logins is the difference between paying for one wasted attempt and paying
    /// for one per file.
    ///
    /// **The retry after a refused run reports nothing**, and that is the one subtlety worth
    /// stating: whatever pieces landed have already been handed to `progress`. Reporting them again
    /// would count one file twice in a job total that only adds, leaving a queue's bar permanently
    /// ahead of the work. The tail in ``copyFile`` still tops the count up to whatever the stream
    /// actually moved.
    private func downloadFile(
        _ request: FTPDownloadRequest,
        progress: (Int64) -> Void,
        isCancelled: () -> Bool
    ) throws -> Int64 {
        let existingLocal = localFileSize(request.localPath)
        if existingLocal == 0,
           let hint = request.expectedSize,
           SegmentedDownloadPlan.isWorthwhile(totalSize: hint, limits: .ftp),
           !segmentation.isRefused,
           let plan = SegmentedDownloadPlan(totalSize: hint, limits: .ftp) {
            if let moved = try downloadInSegments(
                request,
                plan: plan,
                progress: progress,
                isCancelled: isCancelled
            ) {
                return moved
            }
            return try downloadWholeFile(
                request,
                resume: false,
                progress: { _ in },
                isCancelled: isCancelled
            )
        }
        // Only when a local partial exists is a remote size worth fetching; `>` short-circuits so a
        // fresh download (the norm) never pays for the round trip.
        return try downloadWholeFile(
            request,
            resume: existingLocal > 0 && remoteFileSize(request.source) > existingLocal,
            progress: progress,
            isCancelled: isCancelled
        )
    }

    /// One `curl`, the whole file, resuming from a local partial when the caller asks it to.
    private func downloadWholeFile(
        _ request: FTPDownloadRequest,
        resume: Bool,
        progress: (Int64) -> Void,
        isCancelled: () -> Bool
    ) throws -> Int64 {
        try mapErrors(request.source) {
            try transport.download(
                request.remotePath,
                to: request.localPath,
                resume: resume,
                progress: progress,
                isCancelled: isCancelled
            )
        }
    }

    /// Upload `localPath` to `remote`, resuming from a remote partial when one is a proper prefix.
    ///
    /// The remote size is checked here rather than left to `curl -C -`, which would query it too:
    /// `curl` cannot distinguish "no partial to resume" from "the file isn't there at all", so
    /// asking first keeps a fresh upload on the plain path.
    private func uploadFile(
        fromLocal localPath: String,
        remote destination: VFSPath,
        progress: (Int64) -> Void,
        isCancelled: () -> Bool
    ) throws -> Int64 {
        let sourceSize = localFileSize(localPath)
        let existingRemote = sourceSize > Self.resumeUploadThreshold ? remoteFileSize(destination) : 0
        let resume = existingRemote > 0 && existingRemote < sourceSize
        return try mapErrors(destination) {
            try transport.upload(
                localPath,
                to: destination.path,
                resume: resume,
                progress: progress,
                isCancelled: isCancelled
            )
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

    /// Normalize a transport failure onto the shared `VFSError` vocabulary, attaching the `VFSPath`
    /// the transport (which only knows a raw string) couldn't. A `VFSError` thrown from deeper is
    /// passed through unchanged.
    public func mapErrors<T>(_ path: VFSPath, _ body: () throws -> T) throws -> T {
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
            // one down here means a server changed behavior mid-session, which is an I/O failure
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
            ownerName: parsed.ownerName,
            groupName: parsed.groupName,
            inode: 0,
            symlinkDestination: parsed.symlinkDestination,
            // The target's kind is not knowable without another round trip; report a nominal file
            // so the row renders as a live link rather than a broken one, matching `SFTPBackend`.
            symlinkTargetKind: parsed.kind == .symlink ? .file : nil
        )
    }
}
