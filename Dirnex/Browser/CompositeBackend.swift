import DirnexCore
import Foundation

/// The pane's backend: routes each `VFSPath` to the concrete backend that owns it — the
/// real `LocalBackend` for on-disk paths, a lazily-mounted read-only `ArchiveBackend` for
/// `archive:…` paths (PLAN.md §M4 "cash in the VFS abstraction — browse zip/tar as folders").
///
/// Composing, rather than swapping, the pane's backend keeps every existing `self.backend`
/// call site — listing, stat, sizing, copy/move, the shared queue — working unchanged; only
/// the routing is new. An archive is mounted on its first list/stat by spawning `bsdtar`
/// off-main (`ArchiveMounter`, the non-hermetic I/O boundary like `SpotlightSearchRunner`)
/// and cached, so navigating within one never re-reads it. A rewrite that mutates an archive
/// (F8 delete) drops its mount via `invalidateMountedArchive(at:)`, so the next list re-reads it.
final class CompositeBackend: VFSBackend, @unchecked Sendable {
    let local: LocalBackend
    /// Mounted archives keyed by their on-disk path. Guarded by `lock` because listing runs
    /// on detached tasks — two panes can mount the same archive concurrently.
    private let lock = NSLock()
    private var mounted: [String: ArchiveBackend] = [:]
    /// Live SFTP connections keyed by the account descriptor (`sftp://user@host:port`). A connection
    /// is established by the Connect-to-Server flow (`connectSFTP`) before a pane navigates onto it;
    /// each holds a `Process`-driven transport, so listing an SFTP pane routes here (PLAN.md §M5
    /// "browse … through the standard queue"). Guarded by `lock` like the archive mounts.
    private var sftpConnections: [String: SFTPBackend] = [:]

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
    /// but `capabilities(for:)` degrades per path so the panel greys operations off the
    /// *current* location's backend (PLAN.md §M5 "capability degradation").
    var id: VFSBackendID { local.id }
    var capabilities: VFSCapabilities { local.capabilities }

    /// The capabilities of the backend that owns `path`: the full local set on disk, a connected
    /// SFTP account's `[.read, .write, .rename]` (writable but Trash-less/clone-less — the M5
    /// degradation path), and `.read` for a virtual location (an `archive:…` browse or a
    /// search-results listing). A browsed archive is read-only *through the VFS primitives* — its
    /// writes (F8 delete, add-into) go through the app's separate rewrite path, gated by
    /// `isWritableArchive`, not these caps. An SFTP path whose connection has dropped falls back to
    /// `.read` so the pane greys writes rather than offering ones it can't perform. Cheap by design
    /// (no archive mount, no network), like `volumeIdentifier(for:)`.
    func capabilities(for path: VFSPath) -> VFSCapabilities {
        if path.backend == .local {
            // Standing in a Trash, "move to Trash" is not a weaker delete — it is *no* delete:
            // `FileManager.trashItem` on an already-trashed item reports success and does nothing
            // (probed 2026-07-21). Withdrawing the capability is the whole of the inversion the
            // Trash needs — the M5 degradation then turns F8 into a confirmed permanent delete,
            // with no branch in the delete path and no way for a caller to forget to ask.
            return TrashLocations.isInsideTrash(path)
                ? local.capabilities.subtracting(.trash)
                : local.capabilities
        }
        if path.backend.isSFTP { return sftpBackend(for: path.backend)?.capabilities ?? .read }
        // The merged Trash listing is writable-but-Trash-less for the same reason, one level up:
        // its entries are real files that can only be deleted for good. Everything else virtual (an
        // archive browse, a search-results listing) is read-only.
        if path.backend == .trash { return [.read, .write] }
        return .read
    }

    func listDirectory(at path: VFSPath) throws -> [FileEntry] {
        try backend(for: path).listDirectory(at: path)
    }

    func stat(at path: VFSPath) throws -> FileEntry {
        try backend(for: path).stat(at: path)
    }

    func createDirectory(at path: VFSPath) throws {
        try backend(for: path).createDirectory(at: path)
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

    func copyFile(
        at source: VFSPath,
        to destination: VFSPath,
        progress: (Int64) -> Void,
        isCancelled: () -> Bool
    ) throws {
        // A byte copy is performed by whichever backend can move the bytes. An upload (local
        // source → SFTP destination) is the SFTP backend's `put`, so route on the *destination*
        // when it is remote; otherwise route on the source, which covers a download (SFTP source
        // → local destination = the SFTP backend's `get`) and a plain local-to-local copy.
        let mover = destination.backend.isSFTP ? try backend(for: destination) : try backend(
            for: source
        )
        try mover.copyFile(
            at: source,
            to: destination,
            progress: progress,
            isCancelled: isCancelled
        )
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

    private func backend(for path: VFSPath) throws -> any VFSBackend {
        if path.backend == .local { return local }
        if let archivePath = path.backend.archivePath { return try mountedArchive(at: archivePath) }
        if path.backend.isSFTP { return try connectedSFTP(for: path.backend) }
        throw VFSError.unsupported("No backend can handle \(path).")
    }

    private func connectedSFTP(for backendID: VFSBackendID) throws -> SFTPBackend {
        guard let backend = sftpBackend(for: backendID) else {
            throw VFSError.unsupported("Not connected to \(backendID). Reconnect to the server.")
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

    private func mountedArchive(at archivePath: String) throws -> ArchiveBackend {
        lock.lock()
        defer { lock.unlock() }
        if let cached = mounted[archivePath] { return cached }
        let toc = try ArchiveMounter.readTableOfContents(ofArchiveAt: archivePath)
        let backend = ArchiveBackend(archiveOnDiskPath: archivePath, toc: toc)
        mounted[archivePath] = backend
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

        do {
            try process.run()
        } catch {
            throw VFSError.unsupported("Couldn’t run bsdtar to open the archive.")
        }
        // Read to EOF before waiting so a large table of contents can't deadlock a full pipe.
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        guard process.terminationStatus == 0, let text = String(data: data, encoding: .utf8) else {
            let name = (archivePath as NSString).lastPathComponent
            throw VFSError.unsupported("Couldn’t read the archive “\(name)”.")
        }
        return ArchiveTOC(verboseListing: text)
    }
}
