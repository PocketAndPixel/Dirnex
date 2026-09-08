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
    let lock = NSLock()
    private var mounted: [String: Mount] = [:]
    /// The code page the user has declared for an archive whose entry names are not UTF-8, keyed by
    /// the archive's on-disk path (``DirnexCore/ArchiveNameEncoding``).
    ///
    /// It lives here, beside `mounted` and under the same lock, because declaring one **invalidates
    /// the mount**: the whole point is that the table of contents comes out different. Two
    /// dictionaries in two places would make that a rule somebody has to remember, where here it is
    /// one function that cannot do half the job.
    ///
    /// Memory only and never persisted, like `ArchivePassphraseStore` — with the opposite reason.
    /// A passphrase is withheld from every store because it is a secret; this is withheld because it
    /// is a *guess the user made about one archive*, and a wrong one silently outliving the session
    /// would be worse than asking again.
    private var nameEncodings: [String: ArchiveNameEncoding] = [:]
    /// Live SFTP connections keyed by the account descriptor (`sftp://user@host:port`). A connection
    /// is established by the Connect-to-Server flow (`connectSFTP`) before a pane navigates onto it;
    /// each holds a `Process`-driven transport, so listing an SFTP pane routes here (PLAN.md §M5
    /// "browse … through the standard queue"). Guarded by `lock` like the archive mounts.
    var sftpConnections: [String: SFTPBackend] = [:]
    /// Live FTP/FTPS connections keyed by the account descriptor (`ftpes://user@host:port`). The
    /// same shape as `sftpConnections` and for the same reasons — established by the connect flow
    /// before a pane navigates onto it, guarded by `lock` because listing runs on detached tasks.
    var ftpConnections: [String: FTPBackend] = [:]
    /// Live S3 connections keyed by the bucket descriptor (`s3://<key id>@<host>:<port>/…`). The
    /// same shape as the other two, with one difference worth naming: there is no session to keep
    /// alive — every request re-signs — so a "connection" here is the credential plus the endpoint,
    /// held so a pane can keep listing without asking the Keychain on every page.
    var s3Connections: [String: S3Backend] = [:]
    /// Live S3 *account* connections keyed by the account descriptor (`s3a://<key id>@<host>:…`) —
    /// a pane listing an endpoint's buckets rather than one bucket's objects (PLAN.md §M21 Slice 9).
    ///
    /// A second dictionary rather than a wider value type in `s3Connections`, because the two are
    /// keyed by descriptors that can never collide (`S3Addressing.accountScheme`) and answer
    /// different protocols. Registering an account leaves every connected bucket exactly as it was,
    /// which is what makes walking out of a bucket into its account — and back down into another —
    /// two independent connections rather than one being replaced.
    var s3AccountConnections: [String: S3AccountBackend] = [:]
    /// What each live connection was established *with*, keyed by the same descriptor its backend
    /// is — the coordinates and the auth method, never the secret.
    ///
    /// A backend knows its own `location`, which is the descriptor and no more; the **auth method**
    /// and an FTPS pin are the caller's and were dropped on the floor once a connection existed. So
    /// this is where a pane goes to answer "what would it take to open this again", which is what
    /// session restore and a saved workspace have to write down (docs/LOCATION-SUPPORT.md ▸
    /// "Session restore and workspaces drop remote tabs").
    ///
    /// It lives here rather than in the pane because the pane is not the only thing that connects:
    /// entering a bucket from an account, and *expanding* one in a tree, both establish a
    /// connection the pane never saw a form for. One memory, filled where the registration happens.
    var endpoints: [String: ServerEndpoint] = [:]

    init(local: LocalBackend) {
        self.local = local
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

    /// Fill in the symlink targets a listing could not carry, routed to whichever backend owns each
    /// entry (PLAN.md §M25 Slice 4).
    ///
    /// **Grouped by backend rather than resolved one at a time**, because the price this seam exists
    /// to control is a *round trip*: over SFTP an answer costs a whole SSH exec channel, 77 ms
    /// against a loopback server and the same whether it names one link or twelve. Routing per entry
    /// would compile, read correctly and quietly turn a directory of links into a directory of
    /// handshakes.
    ///
    /// One batch really can span backends: a results tab holds hits from anywhere, and a tree draws
    /// several directories at once — the same shape §M24 Slice 6 paid for in the pack sources. The
    /// grouping is stable, so entries come back in the order they arrived.
    func resolvingSymlinkTargets(in entries: [FileEntry]) -> [FileEntry] {
        let unresolved = entries.filter { $0.kind == .symlink && $0.symlinkDestination == nil }
        guard !unresolved.isEmpty else { return entries }

        var targets: [VFSPath: String] = [:]
        for group in Dictionary(grouping: unresolved, by: \.path.backend).values {
            // A backend that cannot even be reached — an archive that will not mount, a connection
            // that is gone — simply answers nothing, because this seam does not throw: an entry
            // whose target stays unknown is refused later by the one caller that needs it, with a
            // sentence naming the link. Raising here would fail the whole copy over a link.
            guard let owner = try? backend(for: group[0].path) else { continue }
            for resolved in owner.resolvingSymlinkTargets(in: group) {
                if let target = resolved.symlinkDestination { targets[resolved.path] = target }
            }
        }

        return entries.map { entry in
            guard let target = targets[entry.path] else { return entry }
            return entry.withSymlinkDestination(target)
        }
    }

    /// What the account owning `path` has failed to carry so far (PLAN.md §M25 Slice 5b).
    ///
    /// Routed per path like everything else here, and it matters more than usual: `CopyEngine` reads
    /// this for each of a job's ends and subtracts, so an answer that folded every connection
    /// together would report one transfer's loss on another's job — quietly, since both numbers look
    /// plausible.
    ///
    /// A path with no backend answers zero rather than raising: a connection that has gone is one
    /// nothing more can be lost on, and a report is not worth failing a job over.
    func metadataTally(at path: VFSPath) -> RemoteMetadataTally {
        guard let owner = try? backend(for: path) else { return .zero }
        return owner.metadataTally(at: path)
    }

    /// Which of a remote row's fields Get Info may change — answered by whoever owns the **row**
    /// (PLAN.md §M25 Slice 5).
    ///
    /// Routed per path rather than per pane for the reason `AttributesRoute` already is: a results
    /// tab holds hits from anywhere, a tree draws several connections at once, and an expanded
    /// bucket in an account pane draws rows on a different backend from the one the pane is on.
    ///
    /// A path with no backend answers "nothing is editable" rather than raising: an unreachable
    /// connection is a reason to show the read-only panel, not to refuse to describe the row at all.
    func editableMetadata(at path: VFSPath) -> RemoteMetadataCapabilities {
        guard let owner = try? backend(for: path) else { return [] }
        return owner.editableMetadata(at: path)
    }

    func applyMetadata(
        _ steps: [RemoteMetadataStep],
        at path: VFSPath
    ) throws -> [RemoteMetadataRefusal] {
        try backend(for: path).applyMetadata(steps, at: path)
    }

    /// A save-back, routed to whoever owns the **destination** (PLAN.md §4 ▸ *Still open*).
    ///
    /// The destination, unambiguously: the source is a temp copy on this disk and the bytes are
    /// being written to the remote side, so the backend that has to carry the precondition is the
    /// one that owns where they land. This replaces the app's old `conditionalWriter(for:)` lookup
    /// — an `as? CompositeBackend` cast plus an `isS3` test — with the router every other verb
    /// already goes through, which is what lets the write-back job be core code.
    func writeBack(
        localPath: String,
        to destination: VFSPath,
        condition: S3WriteCondition,
        progress: (Int64) -> Void,
        isCancelled: () -> Bool
    ) throws -> Bool {
        try backend(for: destination).writeBack(
            localPath: localPath,
            to: destination,
            condition: condition,
            progress: progress,
            isCancelled: isCancelled
        )
    }

    func copyMetadata(at source: VFSPath, to destination: VFSPath) throws {
        try copyMetadata(at: source, to: destination, sourceMetadata: nil)
    }

    /// The same, carrying what the listing already read — so a remote backend finishing a directory
    /// it recreated by hand spends no round trip asking (PLAN.md §M25 Slice 2).
    ///
    /// It routes on the **destination**, unlike its older spelling: the metadata is being *written*,
    /// and for a download that write lands on this machine while the source is the remote one. The
    /// source-routed version answered from the wrong backend for every download, which was invisible
    /// while the whole thing was a no-op.
    func copyMetadata(
        at source: VFSPath,
        to destination: VFSPath,
        sourceMetadata: RemoteSourceMetadata?
    ) throws {
        let owner = destination.backend == .local ? source : destination
        try backend(for: owner).copyMetadata(
            at: source,
            to: destination,
            sourceMetadata: sourceMetadata
        )
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

    /// Whether the backend that owns both ends would attempt a server-side duplicate, forwarded to
    /// it (PLAN.md §M25 Slice 3).
    ///
    /// Forwarded rather than inherited for the reason this file has already paid for twice: the app
    /// holds a composite, so a seam whose default is "do it the old way" answers `false` for every
    /// pane and reports **nothing at all** — same rows, same bytes, and every same-account SFTP copy
    /// quietly staged through this disk. `transferRoute` asks the concrete backend and so does not
    /// need this; anything else holding a pane's backend does, and there is no signal the day one
    /// appears. Unconnected or unroutable ends answer `false`, which is the old behaviour.
    func mayAttemptInternalCopy(from source: VFSPath, to destination: VFSPath) -> Bool {
        guard let owner = try? backend(for: source) else { return false }
        return owner.mayAttemptInternalCopy(from: source, to: destination)
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
    ///
    /// ``ArchiveIdentity/stillDescribesFile(at:)`` rather than a comparison spelled out here: an
    /// unreadable archive must be a *miss*, and that rule is the one thing all three archive caches
    /// have to agree about (`ArchivePreviewCache`, `NestedArchiveRegistry`). Reading it back
    /// costs nothing on the path that matters — a hit is still the single `stat` inside the helper,
    /// and only a re-mount pays the second, beside a subprocess that dwarfs it.
    /// The code page declared for this archive, if any. Every read path asks, so a declaration
    /// reaches the listing, the previews, an extraction and the rewrite alike.
    func nameEncoding(forArchiveAt archivePath: String) -> ArchiveNameEncoding? {
        lock.lock()
        defer { lock.unlock() }
        return nameEncodings[archivePath]
    }

    /// Declare — or, with `nil`, withdraw — the code page this archive's names are stored in, and
    /// drop its mount so the next listing re-reads them.
    ///
    /// Dropping the mount is the whole reason this is one call: a declaration that left the cached
    /// table of contents standing would change nothing on screen, which reads as the choice having
    /// been ignored. The caller still has to refresh the pane; what it cannot get wrong is the
    /// cache underneath.
    func declareNameEncoding(_ encoding: ArchiveNameEncoding?, forArchiveAt archivePath: String) {
        lock.lock()
        defer { lock.unlock() }
        nameEncodings[archivePath] = encoding
        mounted[archivePath] = nil
    }

    private func mountedArchive(at archivePath: String) throws -> ArchiveBackend {
        lock.lock()
        defer { lock.unlock() }
        if let cached = mounted[archivePath], cached.identity.stillDescribesFile(at: archivePath) {
            return cached.backend
        }
        // Read directly rather than through `nameEncoding(forArchiveAt:)`: `lock` is an `NSLock`
        // and is already held here, so going back through the accessor would deadlock.
        let toc = try ArchiveMounter.readTableOfContents(
            ofArchiveAt: archivePath,
            nameEncoding: nameEncodings[archivePath]
        )
        let backend = ArchiveBackend(archiveOnDiskPath: archivePath, toc: toc)
        // An archive that vanished between the read and here has no identity to stamp, and the read
        // above has already thrown; one that appears in that window is stamped on its next list.
        // Either way an unstamped mount is never cached, so it can never go stale.
        if let identity = ArchiveIdentity.current(ofFileAt: archivePath) {
            mounted[archivePath] = Mount(identity: identity, backend: backend)
        }
        return backend
    }
}
