import DirnexCore
import Foundation

/// The pane's backend: routes each `VFSPath` to the concrete backend that owns it — the
/// real `LocalBackend` for on-disk paths, a lazily-mounted read-only `ArchiveBackend` for
/// `archive:…` paths (PLAN.md §M4 "cash in the VFS abstraction — browse zip/tar as folders"), and a
/// connected `SFTPBackend` / `FTPBackend` / `S3Backend` for each live remote account — plus, for
/// S3, an `S3AccountBackend` listing an endpoint's buckets (§M5, §M13, §M21).
///
/// Composing, rather than swapping, the pane's backend keeps every existing `self.backend`
/// call site — listing, stat, sizing, copy/move, the shared queue — working unchanged; only
/// the routing is new. An archive is mounted on its first list/stat by spawning `bsdtar`
/// off-main (`ArchiveMounter`, the non-hermetic I/O boundary like `SpotlightSearchRunner`)
/// and cached, so navigating within one never re-reads it. A rewrite that mutates an archive
/// (F8 delete) drops its mount via `invalidateMountedArchive(at:)`, so the next list re-reads it;
/// a change made *outside* Dirnex — or by deleting the archive and packing a new one under the same
/// name — is caught by the `ArchiveIdentity` each mount is stamped with.
final class CompositeBackend: VFSBackend, @unchecked Sendable {
    let local: LocalBackend
    /// Mounted archives keyed by their on-disk path, each stamped with the identity of the file it
    /// was read from so a path that has since been given a *different* archive re-reads instead of
    /// answering from the old one's table of contents. Guarded by `lock` because listing runs
    /// on detached tasks — two panes can mount the same archive concurrently.
    private let lock = NSLock()
    private var mounted: [String: Mount] = [:]
    /// Live SFTP connections keyed by the account descriptor (`sftp://user@host:port`). A connection
    /// is established by the Connect-to-Server flow (`connectSFTP`) before a pane navigates onto it;
    /// each holds a `Process`-driven transport, so listing an SFTP pane routes here (PLAN.md §M5
    /// "browse … through the standard queue"). Guarded by `lock` like the archive mounts.
    private var sftpConnections: [String: SFTPBackend] = [:]
    /// Live FTP/FTPS connections keyed by the account descriptor (`ftpes://user@host:port`). The
    /// same shape as `sftpConnections` and for the same reasons — established by the connect flow
    /// before a pane navigates onto it, guarded by `lock` because listing runs on detached tasks.
    private var ftpConnections: [String: FTPBackend] = [:]
    /// Live S3 connections keyed by the bucket descriptor (`s3://<key id>@<host>:<port>/…`). The
    /// same shape as the other two, with one difference worth naming: there is no session to keep
    /// alive — every request re-signs — so a "connection" here is the credential plus the endpoint,
    /// held so a pane can keep listing without asking the Keychain on every page.
    private var s3Connections: [String: S3Backend] = [:]
    /// Live S3 *account* connections keyed by the account descriptor (`s3a://<key id>@<host>:…`) —
    /// a pane listing an endpoint's buckets rather than one bucket's objects (PLAN.md §M21 Slice 9).
    ///
    /// A second dictionary rather than a wider value type in `s3Connections`, because the two are
    /// keyed by descriptors that can never collide (`S3Addressing.accountScheme`) and answer
    /// different protocols. Registering an account leaves every connected bucket exactly as it was,
    /// which is what makes walking out of a bucket into its account — and back down into another —
    /// two independent connections rather than one being replaced.
    private var s3AccountConnections: [String: S3AccountBackend] = [:]

    init(local: LocalBackend) {
        self.local = local
    }

    /// Establish (or replace) an SFTP connection for `location`, returning its backend so the caller
    /// can test it (list the home directory) before navigating a pane onto it. `authentication` is a
    /// key file or a password; for password auth `password` is the plaintext the transport feeds to
    /// `sftp` out-of-band (held only in memory for the connection's lifetime, mirrored into the
    /// Keychain separately). An identity-file path is a reference, not a secret, so it is safe to
    /// retain either way.
    @discardableResult
    func connectSFTP(
        location: SFTPLocation,
        authentication: SFTPAuthentication,
        password: String? = nil
    ) -> SFTPBackend {
        let transport = SFTPProcessTransport(
            location: location,
            authentication: authentication,
            password: password
        )
        let backend = SFTPBackend(location: location, transport: transport)
        lock.lock()
        defer { lock.unlock() }
        sftpConnections[location.descriptor] = backend
        return backend
    }

    /// Establish (or replace) an FTP connection for `location`, returning its backend so the caller
    /// can test it before navigating a pane onto it. `password` is the plaintext the transport feeds
    /// to `curl` on stdin (held only in memory for the connection's lifetime, mirrored into the
    /// Keychain separately); `trustedPublicKey` is the certificate pin the user accepted, which is a
    /// public key digest rather than a secret.
    @discardableResult
    func connectFTP(
        location: FTPLocation,
        authentication: FTPAuthentication,
        password: String = "",
        trustedPublicKey: String? = nil
    ) -> FTPBackend {
        let transport = FTPCurlTransport(
            location: location,
            authentication: authentication,
            password: password,
            trustedPublicKey: trustedPublicKey
        )
        let backend = FTPBackend(location: location, transport: transport)
        lock.lock()
        defer { lock.unlock() }
        ftpConnections[location.descriptor] = backend
        return backend
    }

    /// Establish (or replace) an S3 connection for `location`, returning its backend so the caller
    /// can test it (list the bucket root) before navigating a pane onto it. `secretAccessKey` is
    /// the plaintext the transport feeds to `curl` on stdin (held only in memory for the
    /// connection's lifetime, mirrored into the Keychain separately); the *access key id* is not a
    /// secret and rides in the location itself.
    @discardableResult
    func connectS3(location: S3Location, secretAccessKey: String) -> S3Backend {
        let transport = S3CurlTransport(location: location, secretAccessKey: secretAccessKey)
        let backend = S3Backend(location: location, transport: transport)
        lock.lock()
        defer { lock.unlock() }
        s3Connections[location.descriptor] = backend
        return backend
    }

    /// Establish (or replace) a connection to a whole S3 account, returning its backend so the
    /// caller can test it (list the buckets) before navigating a pane onto it. `secretAccessKey` is
    /// the plaintext the transport feeds to `curl` on stdin, exactly as the bucket connection's is.
    ///
    /// An account is a *second* root and never the only one, which is why this sits beside
    /// `connectS3` rather than replacing it: a key scoped to one bucket cannot make this call at
    /// all, and the bucket-rooted connection it does use is untouched by any of this.
    @discardableResult
    func connectS3Account(account: S3Account, secretAccessKey: String) -> S3AccountBackend {
        let transport = S3AccountCurlTransport(
            account: account,
            secretAccessKey: secretAccessKey
        )
        let backend = S3AccountBackend(account: account, transport: transport)
        lock.lock()
        defer { lock.unlock() }
        s3AccountConnections[account.descriptor] = backend
        return backend
    }

    /// Drop the cached mount for the archive at `archivePath`, so its next list/stat re-reads it
    /// from disk with a fresh `bsdtar -tvf`. Called after a rewrite (F8 delete inside an archive)
    /// changes the archive's contents, so the pane's re-list reflects the new table of contents
    /// instead of the stale snapshot mounted before the write.
    func invalidateMountedArchive(at archivePath: String) {
        lock.lock()
        defer { lock.unlock() }
        mounted[archivePath] = nil
    }

    /// The composite presents the local backend's identity and capabilities as its primary,
    /// but `capabilities(for:)` degrades per path so the panel grays operations off the
    /// *current* location's backend (PLAN.md §M5 "capability degradation").
    var id: VFSBackendID { local.id }
    var capabilities: VFSCapabilities { local.capabilities }

    /// The capabilities of the backend that owns `path`: the full local set on disk, a connected
    /// SFTP account's `[.read, .write, .rename]` (writable but Trash-less/clone-less — the M5
    /// degradation path), and `.read` for a virtual location (an `archive:…` browse or a
    /// search-results listing). A browsed archive is read-only *through the VFS primitives* — its
    /// writes (F8 delete, add-into) go through the app's separate rewrite path, gated by
    /// `isWritableArchive`, not these caps. An SFTP path whose connection has dropped falls back to
    /// `.read` so the pane grays writes rather than offering ones it can't perform. Cheap by design
    /// (no archive mount, no network), like `volumeIdentifier(for:)`.
    func capabilities(for path: VFSPath) -> VFSCapabilities {
        if path.backend == .local {
            // Standing in a Trash, "move to Trash" is not a weaker delete — it is *no* delete:
            // `FileManager.trashItem` on an already-trashed item reports success and does nothing
            // (probed 2026-07-21). Withdrawing the capability is the whole of the inversion the
            // Trash needs — the M5 degradation then turns F8 into a confirmed permanent delete,
            // with no branch in the delete path and no way for a caller to forget to ask.
            //
            // `.rename` goes with it, and for a reason of the Trash's own: **Put Back is keyed on
            // the name in the trash**. The origin lives in the trash folder's `.DS_Store` as a
            // `ptbL`/`ptbN` pair looked up by that name (`TrashPutBack`), so renaming a trashed
            // item orphans its record — Put Back stops working, with nothing on screen to say so
            // and no way back. Finder refuses the same gesture. Withdrawing the capability rather
            // than gating the flows covers every route at once: the merged Trash listing, a pane
            // navigated into `~/.Trash`, a volume's `.Trashes`, and a tree over any of them.
            return TrashLocations.isInsideTrash(path)
                ? local.capabilities.subtracting([.trash, .rename])
                : local.capabilities
        }
        if path.backend.isSFTP { return sftpBackend(for: path.backend)?.capabilities ?? .read }
        if path.backend.isFTP { return ftpBackend(for: path.backend)?.capabilities ?? .read }
        // A connected bucket is `[.read, .write, .rename]` — Trash-less and clone-less, the same M5
        // degradation shape as SFTP. A path whose connection is gone falls back to `.read` for the
        // reason SFTP does: gray the writes rather than offer ones there is no credential to
        // perform. This stopped being a no-op when the write half landed — before it, both sides of
        // the `??` were the same value, so the fallback was untestable and provably harmless.
        if path.backend.isS3 { return s3Backend(for: path.backend)?.capabilities ?? .read }
        // An account pane is `[.read, .write]`, and it means something narrower: the writes are
        // *creating and deleting buckets*, which is what F7 and F8 do on rows that are buckets.
        // There is deliberately no `.rename` — S3 cannot rename a bucket at any level — and
        // `acceptsUploads` is false for this backend, so F5 into it is refused up front rather than
        // failing inside the queue (`VFSBackendID.acceptsUploads`).
        if path.backend.isS3Account {
            return s3AccountBackend(for: path.backend)?.capabilities ?? .read
        }
        // The merged Trash listing is writable-but-Trash-less for the same reason, one level up:
        // its entries are real files that can only be deleted for good. Everything else virtual (an
        // archive browse, a search-results listing) is read-only.
        if path.backend == .trash { return [.read, .write] }
        // The merged iCloud listing's entries are ordinary local files and folders, so everything a
        // local location can do to them applies — including the Trash, which is where deleting one
        // should send it. Only the container is virtual, and the flows that need a real directory
        // under them ask `writeDirectory`, which points them at the CloudDocs container.
        if path.backend == .icloud { return local.capabilities }
        return .read
    }

    func listDirectory(at path: VFSPath) throws -> [FileEntry] {
        try backend(for: path).listDirectory(at: path)
    }

    func stat(at path: VFSPath) throws -> FileEntry {
        try backend(for: path).stat(at: path)
    }

    /// Routed like every other read, and it has to be: this is what a pane actually holds, so a
    /// `subtreeListing` left unforwarded here inherits the protocol's `nil` default and every search
    /// walks — including the one backend that need not (PLAN.md §M22, `S3Backend+Subtree.swift`).
    ///
    /// That failure has no symptom. A walk of a bucket returns the *same rows*, correctly, at one
    /// billed request per folder instead of one per 1000 keys — so nothing is wrong on screen and
    /// the only evidence is the bill and the wait. It is this project's most-repeated shape
    /// (docs/NOTES.md: name the new backend at every site that lists the old ones) arriving as an
    /// omission rather than a wrong branch, which is why the forward is spelled out with a reason
    /// instead of sitting silently among its neighbours.
    func subtreeListing(at path: VFSPath, isCancelled: () -> Bool) throws -> VFSSubtreeListing? {
        try backend(for: path).subtreeListing(at: path, isCancelled: isCancelled)
    }

    func createDirectory(at path: VFSPath) throws {
        try backend(for: path).createDirectory(at: path)
    }

    func createFile(at path: VFSPath) throws {
        try backend(for: path).createFile(at: path)
    }

    func moveItem(at source: VFSPath, to destination: VFSPath) throws {
        // A move whose ends live on different backends (local ⇄ SFTP) is not an in-place rename —
        // signal EXDEV so `CopyEngine` falls back to copy-then-delete, exactly as it does for a
        // cross-volume local move. A same-backend move routes normally (local rename, SFTP rename).
        guard source.backend == destination.backend else {
            throw VFSError.io(path: source, code: EXDEV)
        }
        try backend(for: source).moveItem(at: source, to: destination)
    }

    func removeItem(at path: VFSPath) throws {
        try backend(for: path).removeItem(at: path)
    }

    @discardableResult
    func trashItem(at path: VFSPath) throws -> VFSPath? {
        try backend(for: path).trashItem(at: path)
    }

    func cloneItem(at source: VFSPath, to destination: VFSPath) throws -> Bool {
        try backend(for: source).cloneItem(at: source, to: destination)
    }

    func createSymbolicLink(at destination: VFSPath, withDestination target: String) throws {
        try backend(for: destination).createSymbolicLink(at: destination, withDestination: target)
    }

    func copyMetadata(at source: VFSPath, to destination: VFSPath) throws {
        try backend(for: source).copyMetadata(at: source, to: destination)
    }

    func volumeIdentifier(for path: VFSPath) -> String? {
        // The queue calls this for every source of every job and it must stay cheap — never
        // mount an archive here. A non-local path reports "one indistinguishable volume".
        path.backend == .local ? local.volumeIdentifier(for: path) : nil
    }

    // MARK: - Routing

    /// Internal rather than private so `CompositeBackend+Transfer` can route a copy through it —
    /// Swift's `private` does not cross files (docs/NOTES.md ▸ Lint ceilings and file splitting).
    func backend(for path: VFSPath) throws -> any VFSBackend {
        if path.backend == .local { return local }
        if let archivePath = path.backend.archivePath { return try mountedArchive(at: archivePath) }
        if path.backend.isSFTP { return try connectedSFTP(for: path.backend) }
        if path.backend.isFTP { return try connectedFTP(for: path.backend) }
        if path.backend.isS3 { return try connectedS3(for: path.backend) }
        if path.backend.isS3Account { return try connectedS3Account(for: path.backend) }
        throw VFSError.unsupported(.noBackendForPath(path: "\(path)"))
    }

    private func connectedS3Account(for backendID: VFSBackendID) throws -> S3AccountBackend {
        guard let backend = s3AccountBackend(for: backendID) else {
            throw VFSError.unsupported(.serverNotConnected(server: "\(backendID)"))
        }
        return backend
    }

    /// The connected S3 account backend for `backendID`, or `nil` when there's no live connection —
    /// the non-throwing lookup `capabilities(for:)` needs (it must never throw and must stay cheap).
    private func s3AccountBackend(for backendID: VFSBackendID) -> S3AccountBackend? {
        lock.lock()
        defer { lock.unlock() }
        return s3AccountConnections[backendID.rawValue]
    }

    /// The connected backend that can attach a **precondition** to a write at `path`, or `nil` when
    /// nothing here can (PLAN.md §M21 Slice 18).
    ///
    /// Named for the question rather than for the type, because the answer is *not* "is this S3":
    /// an unconnected bucket, an account root, an archive member and a local file all answer `nil`,
    /// and a caller spelling `path.backend.isS3` would get `true` for two of those. One funnel is
    /// what keeps that rule from being written a second way — this milestone has re-derived the
    /// one-rule-several-spellings finding often enough to stop restating it (docs/NOTES.md ▸ AppKit).
    ///
    /// Deliberately concrete rather than a protocol: S3 is the only backend with a conditional
    /// write, and a protocol over one conformer would hide which backend a call site is really
    /// talking to while offering nothing a second implementation could use.
    func conditionalWriter(for path: VFSPath) -> S3Backend? {
        guard path.backend.isS3 else { return nil }
        return s3Backend(for: path.backend)
    }

    private func connectedS3(for backendID: VFSBackendID) throws -> S3Backend {
        guard let backend = s3Backend(for: backendID) else {
            throw VFSError.unsupported(.serverNotConnected(server: "\(backendID)"))
        }
        return backend
    }

    /// The connected S3 backend for `backendID`, or `nil` when there's no live connection — the
    /// non-throwing lookup `capabilities(for:)` needs (it must never throw and must stay cheap).
    private func s3Backend(for backendID: VFSBackendID) -> S3Backend? {
        lock.lock()
        defer { lock.unlock() }
        return s3Connections[backendID.rawValue]
    }

    private func connectedFTP(for backendID: VFSBackendID) throws -> FTPBackend {
        guard let backend = ftpBackend(for: backendID) else {
            throw VFSError.unsupported(.serverNotConnected(server: "\(backendID)"))
        }
        return backend
    }

    /// The connected FTP backend for `backendID`, or `nil` when there's no live connection — the
    /// non-throwing lookup `capabilities(for:)` needs (it must never throw and must stay cheap).
    private func ftpBackend(for backendID: VFSBackendID) -> FTPBackend? {
        lock.lock()
        defer { lock.unlock() }
        return ftpConnections[backendID.rawValue]
    }

    private func connectedSFTP(for backendID: VFSBackendID) throws -> SFTPBackend {
        guard let backend = sftpBackend(for: backendID) else {
            throw VFSError.unsupported(.serverNotConnected(server: "\(backendID)"))
        }
        return backend
    }

    /// The connected SFTP backend for `backendID`, or `nil` when there's no live connection — the
    /// non-throwing lookup `capabilities(for:)` needs (it must never throw and must stay cheap).
    private func sftpBackend(for backendID: VFSBackendID) -> SFTPBackend? {
        lock.lock()
        defer { lock.unlock() }
        return sftpConnections[backendID.rawValue]
    }

    /// One mounted archive and the file it was read from.
    private struct Mount {
        let identity: ArchiveIdentity
        let backend: ArchiveBackend
    }

    /// The backend for the archive at `archivePath`, mounting it on first use and re-mounting it
    /// whenever the file there is no longer the one that was read.
    ///
    /// The identity check is what makes the mount a cache rather than a memory: an archive that is
    /// deleted and repacked under the same name — the ordinary way to redo one — would otherwise go
    /// on listing the members it held when the pane first entered it, for the life of the window.
    /// One `stat` per list, against a `bsdtar` spawn saved, so it costs nothing worth measuring.
    private func mountedArchive(at archivePath: String) throws -> ArchiveBackend {
        let identity = ArchiveIdentity.current(ofFileAt: archivePath)
        lock.lock()
        defer { lock.unlock() }
        if let identity, let cached = mounted[archivePath], cached.identity == identity {
            return cached.backend
        }
        let toc = try ArchiveMounter.readTableOfContents(ofArchiveAt: archivePath)
        let backend = ArchiveBackend(archiveOnDiskPath: archivePath, toc: toc)
        // An archive that vanished between the stat and the read has no identity to stamp, and the
        // read above has already thrown; one that appears in that window is stamped on its next
        // list. Either way an unstamped mount is never cached, so it can never go stale.
        if let identity { mounted[archivePath] = Mount(identity: identity, backend: backend) }
        return backend
    }
}

/// Reads an archive's table of contents by spawning `bsdtar -tvf` and handing the verbose
/// listing to the pure `ArchiveTOC` parser. The non-hermetic subprocess I/O lives here in the
/// app layer, mirroring `SpotlightSearchRunner`; all parsing stays tested in `DirnexCore`.
enum ArchiveMounter {
    static func readTableOfContents(ofArchiveAt archivePath: String) throws -> ArchiveTOC {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/bsdtar")
        process.arguments = ["-tvf", archivePath]
        let pipe = Pipe()
        process.standardOutput = pipe
        // Discard stderr so a libarchive warning neither pollutes the listing nor risks a
        // second-pipe deadlock; a real failure shows up as a non-zero exit below.
        process.standardError = FileHandle.nullDevice

        let awaitExit = ProcessWaiting.exitWaiter(for: process)
        do {
            try process.run()
        } catch {
            throw VFSError.unsupported(.archiveToolUnavailableForRead)
        }
        // Read to EOF before waiting so a large table of contents can't deadlock a full pipe.
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        awaitExit()

        guard process.terminationStatus == 0, let text = String(data: data, encoding: .utf8) else {
            let name = (archivePath as NSString).lastPathComponent
            throw VFSError.unsupported(.archiveUnreadable(archive: name))
        }
        return ArchiveTOC(verboseListing: text)
    }
}
