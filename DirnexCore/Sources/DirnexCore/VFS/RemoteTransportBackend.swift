import Foundation

/// The write verbs a remote file transport offers, whatever wire protocol it speaks.
///
/// `FTPTransport` and `SFTPTransport` both refine this: `curl`'s `MKD`/`RNFR`+`RNTO`/`DELE`/`RMD`
/// and `sftp`'s `mkdir`/`rename`/`rm`/`rmdir` are the same operations under different names,
/// which is what lets `RemoteTransportBackend` express the writes once for both.
public protocol RemoteWriteTransport: Sendable {
    /// Create one directory. The parent must already exist — neither protocol has a `mkdir -p`.
    func makeDirectory(_ remotePath: String) throws

    /// Create an empty regular file at `remotePath` — ⇧F4 "Edit File…" on a server (PLAN.md §M11).
    ///
    /// **Neither protocol has a create-if-absent, so this one may overwrite and the caller is what
    /// stops it.** ``RemoteTransportBackend/createFile(at:)`` refuses an occupied name before
    /// calling here; what each transport owes is to write zero bytes to a name it is told is free,
    /// and to get as close to harmless as its protocol allows if it turns out not to be.
    ///
    /// Measured 2026-08-23 against a real `sshd` and a real FTP server, because the two protocols
    /// differ in how bad "not free after all" is. Over FTP `APPE` **creates when absent and leaves
    /// an existing file untouched**, so the window between the check and the write is benign there;
    /// over SFTP `put` truncates, `put -a` can create nothing, and `rename` overwrites, so the
    /// window is real and unavoidable. Neither is expressible as a flag on ``upload``, which is why
    /// this is its own verb rather than a zero-byte transfer.
    func createEmptyFile(_ remotePath: String) throws

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
public protocol RemoteTransportBackend: ConnectionScopedBackend {
    /// The transport the shared write verbs are issued through.
    var writeTransport: any RemoteWriteTransport { get }

    /// Normalize a transport failure onto the shared `VFSError` vocabulary, attaching the `VFSPath`
    /// the transport (which only knows a raw string) couldn't. Each protocol's transport throws its
    /// own error type, so this is the one piece that cannot be shared.
    func mapErrors<T>(_ path: VFSPath, _ body: () throws -> T) throws -> T
}

public extension RemoteTransportBackend {
    // `requireOwnBackend` is `ConnectionScopedBackend`'s — the same guard `S3Backend` needs, which
    // is why it sits one level up rather than here.

    /// Create one directory, answering ``VFSError/alreadyExists(_:)`` when the name is taken —
    /// which neither protocol says on its own, and which a caller cannot recover without.
    ///
    /// **The refusal is generic on both wires, so it has to be disambiguated here.** Measured
    /// 2026-08-23: `sftp`'s `mkdir` onto an existing directory answers a bare
    /// `remote mkdir "…": Failure` (OpenSSH's SFTP v3 has no "already exists" status, so EEXIST
    /// arrives as `SSH_FX_FAILURE`), which classifies as `.failure` → `.io`; FTP's `MKD` answers
    /// **550**, which is FTP's one ambiguous "file unavailable" and is read as `.notFound`. Local
    /// `mkdir(2)` has `EEXIST` and needs none of this, which is exactly why the gap was invisible:
    /// every caller was written and tested against the one backend that answers correctly.
    ///
    /// What it cost was a `catch` that never fires. `PanelViewController+Copy.submitBranchTransfer`
    /// skips an intermediate directory that is already there by catching `.alreadyExists`, so a
    /// tree-mode branch transfer into a remote destination failed outright the moment one existed;
    /// and F7 on a taken name reported `.io`'s or `.notFound`'s sentence instead of "an item with
    /// that name already exists". One backend-side answer fixes both, where two caller-side
    /// workarounds would have been the third and fourth copies of a rule this file keeps finding on
    /// the wrong side of a fix.
    ///
    /// **Only a failure pays for the extra round trip**, and only a failure can: asking first would
    /// bill every create for a question the happy path never needs, and would still race. That is
    /// the shape `S3Backend`'s own existence check settled on — the cheap answer raises the
    /// question, and only a name about to be refused pays to have it answered.
    ///
    /// A `stat` that itself fails leaves the original error standing rather than reading as "the
    /// name is free": the two directions are not equal, and inventing `.alreadyExists` from a
    /// listing nobody could get would refuse a create that should have been attempted.
    func createDirectory(at path: VFSPath) throws {
        try requireOwnBackend(path)
        do {
            try mapErrors(path) { try writeTransport.makeDirectory(path.path) }
        } catch {
            // Something already occupying the name is the answer the caller can act on, whatever
            // the server's own reason was — a file or a symlink included, since the contract is
            // "something is already there" rather than "a directory is".
            if (try? stat(at: path)) != nil { throw VFSError.alreadyExists(path) }
            throw error
        }
    }

    /// Create an empty file at `path` — the ⇧F4 "Edit File…" route on a server (PLAN.md §M11).
    ///
    /// **The `stat` is the whole guard, and it is load-bearing twice over rather than once.**
    /// Neither protocol offers a create-if-absent — measured 2026-08-23 against a real `sshd` and a
    /// real FTP server — so an unguarded write is destructive in two different ways, and only one of
    /// them is the one everybody expects:
    ///
    /// - **It truncates.** `put` and `STOR` alike replace an existing file's bytes with none, so
    ///   ⇧F4 on a name that is already taken would empty the very document the user was reaching
    ///   for. That is the case ``VFSBackend/createFile(at:)``'s contract exists to forbid.
    /// - **Over SFTP it also writes somewhere else entirely.** `put <local> <an existing directory>`
    ///   exits **0** having created `<directory>/<the local file's basename>` — so a create aimed at
    ///   a folder's name would succeed, report success, and leave a file named after a temporary
    ///   file nobody chose inside a folder nobody was editing. (`curl` refuses the same thing with
    ///   550, so this half is SFTP's alone and would not have shown up on the FTP side.)
    ///
    /// The window between the check and the write cannot be closed here the way ``S3Backend`` closes
    /// it with `If-None-Match: *`: there is no conditional write in either protocol. What FTP has
    /// instead is `APPE`, which creates an absent file and leaves a present one *untouched*, so on
    /// that side a lost race is merely a create that quietly did nothing — see
    /// ``RemoteWriteTransport/createEmptyFile(_:)``. Over SFTP the window is real, and it is stated
    /// rather than papered over: three candidates were measured and none of them is exclusive
    /// (`put` truncates, `put -a` cannot create, `rename` overwrites).
    func createFile(at path: VFSPath) throws {
        try requireOwnBackend(path)
        guard path.parent != nil else { throw VFSError.alreadyExists(path) }
        if (try? stat(at: path)) != nil { throw VFSError.alreadyExists(path) }
        try mapErrors(path) { try writeTransport.createEmptyFile(path.path) }
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
