import Foundation

/// What a backend can do. Panels gray out operations a backend lacks
/// (PLAN.md §M5 "capability degradation"), so this is descriptive, not aspirational.
public struct VFSCapabilities: OptionSet, Sendable, Hashable {
    public let rawValue: Int

    public init(rawValue: Int) {
        self.rawValue = rawValue
    }

    public static let read = VFSCapabilities(rawValue: 1 << 0)
    public static let write = VFSCapabilities(rawValue: 1 << 1)
    /// Move-to-Trash is available (vs. only permanent delete).
    public static let trash = VFSCapabilities(rawValue: 1 << 2)
    /// Copy-on-write clones (APFS `COPYFILE_CLONE`).
    public static let clone = VFSCapabilities(rawValue: 1 << 3)
    /// In-place rename without a copy.
    public static let rename = VFSCapabilities(rawValue: 1 << 4)
    /// Live change notifications (FSEvents and friends).
    public static let watch = VFSCapabilities(rawValue: 1 << 5)
    /// ``VFSBackend/copyFile(at:to:progress:isCancelled:)`` can move bytes with **both** ends
    /// inside this backend — the local disk's ordinary copy, and S3's server-side
    /// `x-amz-copy-source`, where the bytes never leave the service.
    ///
    /// It is not implied by `.write`, and the difference is the whole reason it has a name. FTP is
    /// writable and has no copy verb at all: its `copyFile` is an *upload* or a *download*, so
    /// duplicating a file within one account — never mind between two accounts — has to be staged
    /// through this disk (``RelayCopy``). A router asking "who can move these bytes" needs that
    /// answer per backend, and the alternative is spelling the backends out at the one site that
    /// asks, which is this project's most repeated bug.
    ///
    /// **SFTP is the case this bit deliberately does not cover, and it is why
    /// ``VFSBackend/mayAttemptInternalCopy(from:to:)`` exists beside it.** OpenSSH's `copy-data`
    /// extension gives `sftp` a real server-side `cp` — measured, 64 MiB in 0.09 s with nothing on
    /// the wire — but a server need not advertise it and no request asks whether it has. A promise
    /// that can be withdrawn by the next server is not a capability; it is an attempt with a
    /// fallback.
    public static let internalCopy = VFSCapabilities(rawValue: 1 << 6)

    /// The delete path a panel should take on a backend with these capabilities — the
    /// concrete "capability degradation" decision (PLAN.md §M5: "no Trash on SFTP →
    /// explicit delete confirm"). A backend with a Trash gets the reversible move; a
    /// writable but Trash-less backend (SFTP) falls back to a permanent delete the UI
    /// gates behind a confirmation; a read-only location can't delete at all.
    public var deleteStrategy: DeleteStrategy {
        guard contains(.write) else { return .unsupported }
        return contains(.trash) ? .trash : .permanent
    }
}

/// How a delete request (F8) resolves against a backend's capabilities, so the panel can
/// degrade gracefully instead of hard-coding "everything has a Trash" (PLAN.md §M5).
public enum DeleteStrategy: Sendable, Equatable {
    /// Move to the Trash — reversible, so it proceeds without a scary prompt (Finder-like).
    case trash
    /// No Trash here, but the backend can delete: a permanent delete the UI confirms first,
    /// because it can't be undone.
    case permanent
    /// The backend can't delete at all — the operation is grayed out.
    case unsupported
}

/// Errors a backend raises, normalized across backends so the UI can react without
/// knowing which backend produced them.
public enum VFSError: Error, Sendable, Equatable {
    case notFound(VFSPath)
    case notADirectory(VFSPath)
    case permissionDenied(VFSPath)
    /// The target already exists — a directory create or a move/rename onto an
    /// occupied path (the conflict engine in M2 decides what to do about it).
    case alreadyExists(VFSPath)
    /// Any other POSIX/backend failure, carrying the raw errno for diagnostics.
    case io(path: VFSPath, code: Int32)
    /// The backend cannot do this, for a reason the user is shown. The payload is a named
    /// ``VFSUnsupportedReason`` rather than a `String` so the sentence can be translated — it
    /// reaches the screen through `VFSErrorText.sentence(for:)`, where a bare literal would be
    /// invisible to string extraction (PLAN.md §M12 Slice 11).
    case unsupported(VFSUnsupportedReason)

    /// Map a POSIX `errno` to the closest semantic case.
    static func fromErrno(_ code: Int32, path: VFSPath) -> VFSError {
        switch code {
        case ENOENT: .notFound(path)
        case ENOTDIR: .notADirectory(path)
        case EACCES, EPERM: .permissionDenied(path)
        case EEXIST, ENOTEMPTY: .alreadyExists(path)
        default: .io(path: path, code: code)
        }
    }
}

/// The protocol every filesystem backend implements. M1 needed only read access;
/// M2 grows it with the write primitives below.
///
/// Backends are `Sendable` and their methods are safe to call off the main thread —
/// neither listing nor a file operation may block the UI (PLAN.md §1). The write
/// primitives are the "instant" operations (create/rename/delete); byte-moving
/// copy/move with progress is layered on top by the M2 operation engine, not here.
///
/// A backend that lacks a capability need not implement its write methods: the
/// default implementations throw `.unsupported`, and the panel grays the operation
/// out via `capabilities` (PLAN.md §M5 "capability degradation").
public protocol VFSBackend: Sendable {
    var id: VFSBackendID { get }
    var capabilities: VFSCapabilities { get }

    /// The capabilities that apply to `path` specifically. Single-backend implementations
    /// return their backend-wide `capabilities` (the default), but a *routing* backend that
    /// composes several concrete backends (the app's `CompositeBackend`) overrides this to
    /// report the capabilities of whichever backend owns `path` — so a panel grays out
    /// operations per the *current* location's backend, not the composite's primary
    /// (PLAN.md §M5 "panels gray out unsupported ops per backend").
    func capabilities(for path: VFSPath) -> VFSCapabilities

    /// List the immediate children of `path` (excluding `.` and `..`), unsorted.
    /// Throws `VFSError.notADirectory` if `path` is a file.
    func listDirectory(at path: VFSPath) throws -> [FileEntry]

    /// Stat a single entry (does not follow the entry itself if it is a symlink).
    func stat(at path: VFSPath) throws -> FileEntry

    /// Every entry beneath `path` at every depth, for a backend that can answer that in **fewer
    /// requests than a walk would take** — or `nil`, the default, meaning there is no such shortcut
    /// and the caller should walk with `listDirectory` (PLAN.md §M22).
    ///
    /// Two backends fill it, for two unrelated reasons, and between them they say what the seam is
    /// for. S3 is not a tree at all — it is a flat keyspace that *renders* as one, so `ListObjectsV2`
    /// with no delimiter answers the whole subtree at 1000 keys a request. SFTP browses a real
    /// filesystem where a listing genuinely is one round trip per directory, but it can borrow the
    /// server's own `find` over an SSH exec channel and have the tree walked *there*, at 501
    /// directories in 98 ms against 34.3 s of per-directory connections (measured 2026-08-16).
    ///
    /// `nil` is therefore not "this backend is slow"; it is "asking cannot beat walking, or the one
    /// way of asking is unavailable on this server". FTP is the first, an `sftp`-only account the
    /// second — and the second is decided per connection, at run time, which is why the answer is a
    /// return value rather than a capability flag.
    ///
    /// `isCancelled` is polled between pages: the whole point is that the call may be long, and a
    /// shortcut that could not be abandoned would be worse than the walk it replaces. Implementers
    /// throw `CancellationError` when it answers `true`.
    ///
    /// The entries must be indistinguishable from what a walk would have produced — real paths,
    /// leaf names — since the caller renders them beside hits from backends that did walk. An
    /// implementation that stopped short of the whole subtree says so through
    /// ``VFSSubtreeListing/isComplete`` rather than by returning what it has and staying quiet.
    func subtreeListing(at path: VFSPath, isCancelled: () -> Bool) throws -> VFSSubtreeListing?

    /// Create a single directory at `path`. Throws `.alreadyExists` if something is
    /// already there and `.notFound` if the parent does not exist (no intermediate
    /// directories are created — mirrors `mkdir(2)`).
    ///
    /// **Unlike ``moveItem(at:to:)``'s, this promise is kept — but it was not free, and one backend
    /// is a deliberate exception.** Only local `mkdir(2)` says "already exists" on its own
    /// (`EEXIST`): SFTP answers a bare `Failure` and FTP a 550, so `RemoteTransportBackend` earns
    /// the case by disambiguating a failed create with a `stat`. `S3Backend` is the exception and
    /// throws nothing — a folder there is a zero-byte marker, so writing one twice leaves one
    /// object and there is nothing a second create could destroy; its own doc comment argues the
    /// asymmetry against `createFile`, which *does* check because an empty PUT would replace a real
    /// file. A caller that must know whether the name was free therefore cannot rely on this alone
    /// over S3, and none does: the two that care (`PanelViewController+Copy.submitBranchTransfer`
    /// skipping an intermediate directory, and `UndoJournal`'s rebuild) both want "make sure it
    /// exists", which idempotence satisfies outright.
    func createDirectory(at path: VFSPath) throws

    /// Create an empty regular file at `path`. Throws `.alreadyExists` if anything is already
    /// there — deliberately never truncating, because the one caller is ⇧F4 "Edit File…", where
    /// an existing name means *open that file* and silently emptying it would destroy the very
    /// document the user was reaching for (PLAN.md §M11).
    func createFile(at path: VFSPath) throws

    /// Move or rename `source` to `destination` within this backend. Same-volume moves
    /// are an atomic rename; a cross-volume — or cross-backend — move throws `EXDEV`, which is the
    /// operation engine's cue to fall back to copy-then-delete rather than a failure.
    ///
    /// **An occupied `destination` is silently replaced, and a caller that must not clobber has to
    /// check first.** This used to promise `.alreadyExists` and no backend has ever delivered it for
    /// the case that matters — measured across all four, 2026-08-23:
    ///
    /// - **Local** is `rename(2)`, which *replaces* a destination file (verified: the bytes
    ///   afterwards are the source's). `.alreadyExists` comes back only from `ENOTEMPTY`, i.e. a
    ///   directory onto a **non-empty** directory; a file onto a file, and a directory onto an
    ///   *empty* directory, both succeed.
    /// - **SFTP** is OpenSSH's `rename`, which uses the POSIX-rename extension and overwrites, exit
    ///   0. Its directory-onto-non-empty-directory refusal is a bare `Failure`, so it arrives as
    ///   `.io`, not `.alreadyExists`.
    /// - **FTP** is `RNFR`/`RNTO`, which overwrote on the server measured; the refusal is a 550,
    ///   which is FTP's ambiguous "file unavailable" and is read as `.notFound`. Both halves are the
    ///   server's choice, not ours.
    /// - **S3** is a copy followed by a delete, and `CopyObject` overwrites unconditionally. (A
    ///   prefix never gets this far — it throws `EXDEV` so the engine runs the walk.)
    ///
    /// So there is no error a caller can key on, and the three that must not overwrite all guard
    /// themselves rather than relying on this: `PanelViewController+Rename` and
    /// `PanelViewController+TrashRestore` each `stat` the destination first — both with a comment
    /// naming `rename(2)`'s overwrite — and `MultiRename.plan` refuses a colliding name as
    /// `.collision` before any job is applied. `CopyEngine` calls this only for a target its
    /// conflict resolution has already made free.
    func moveItem(at source: VFSPath, to destination: VFSPath) throws

    /// Permanently remove `path`, recursively for directories. This is not reversible;
    /// prefer `trashItem` where the backend supports a Trash.
    func removeItem(at path: VFSPath) throws

    /// Move `path` to the Trash, returning its resulting location when the backend
    /// reports one (undo restores from there). Backends without a Trash throw
    /// `.unsupported`; check `capabilities.contains(.trash)` first.
    @discardableResult
    func trashItem(at path: VFSPath) throws -> VFSPath?

    // MARK: - Byte-copy primitives (driven by the operation engine)

    /// Attempt a copy-on-write clone of a whole item (a file, or a directory *and* its
    /// entire subtree) from `source` to `destination` in one shot — APFS's instant
    /// same-volume copy (PLAN.md §2 "COPYFILE_CLONE fast path"). `destination` must not
    /// already exist.
    ///
    /// Returns `true` when the clone happened. Returns `false` — not an error — when a
    /// clone isn't possible *here* (a cross-volume copy, or a filesystem without
    /// copy-on-write), so `CopyEngine` falls back to a chunked recursive copy. Still
    /// throws for real failures (`.alreadyExists`, `.permissionDenied`, …). The default
    /// reports "no clone support", so a backend need only implement it to opt in.
    func cloneItem(at source: VFSPath, to destination: VFSPath) throws -> Bool

    /// Copy one regular file's bytes from `source` to a not-yet-existing `destination`,
    /// preserving metadata (permissions, timestamps, extended attributes, Finder tags).
    /// `progress` is called with the number of bytes copied by each chunk, so the engine
    /// can drive a determinate progress bar; `isCancelled` is polled between chunks and,
    /// when it returns `true`, the copy throws `CancellationError` after removing the
    /// partial destination. This is the chunked fallback used when cloning isn't available.
    func copyFile(
        at source: VFSPath,
        to destination: VFSPath,
        progress: (Int64) -> Void,
        isCancelled: () -> Bool
    ) throws

    /// The same copy, told how large `source` is when the caller already knows.
    ///
    /// A **hint**, never a promise and never a request for a probe: a backend is free to ignore it,
    /// and the default does exactly that by forwarding to the spelling above. What it buys is a
    /// decision a transfer cannot otherwise make without paying for it — S3 splits a download over
    /// several connections above a threshold, and asking the service for the size first would cost a
    /// full handshake on every small file to answer a question that only matters for large ones
    /// (docs/HISTORY.md ▸ After M19).
    ///
    /// Additive for the reason every other widened verb in this project is: a protocol requirement
    /// cannot carry a default parameter, so growing the existing one would rewrite every conformance
    /// for a capability most backends have no use for. The forwarding default is safe here because
    /// the two spellings produce the identical file — a backend that ignores the hint is slower, not
    /// wrong — which is the test this project applies before letting a default stand in at all.
    ///
    /// Callers that hold a size from a listing they already made should pass it. Anything that would
    /// have to *ask* should not: with no hint, behaviour is exactly what it was.
    func copyFile(
        at source: VFSPath,
        to destination: VFSPath,
        expectedSize: Int64?,
        progress: (Int64) -> Void,
        isCancelled: () -> Bool
    ) throws

    /// The same copy, also told what the source's **metadata** was, so a backend that can carry a
    /// mode and a modification time across the wire does not have to go and ask (PLAN.md §M25).
    ///
    /// Additive for the same reason `expectedSize` was, and it earns its place the same way: the
    /// caller already holds the answer. A download's source is remote, so learning its mode costs a
    /// whole connection — 71 ms against a loopback `sshd`, a real TCP + SSH handshake over a network
    /// — while every caller that copies a file has the `FileEntry` a listing produced. With the hint
    /// **both directions are free**: an upload reads its local source, and a download applies the
    /// listing's own answer to the local destination with plain syscalls.
    ///
    /// The forwarding default drops the hint, which is honest rather than merely convenient: a
    /// backend that ignores it is precisely a backend that does not carry metadata, so the copy
    /// behaves exactly as it did before and nothing claims otherwise.
    func copyFile(
        at source: VFSPath,
        to destination: VFSPath,
        hint: CopySourceHint,
        progress: (Int64) -> Void,
        isCancelled: () -> Bool
    ) throws

    /// Recreate a symbolic link at `destination` pointing at the raw (unresolved) target
    /// text `target`. Copying a symlink duplicates the link itself, never the file it
    /// points at (matching `clonefile`/`cp -R` semantics).
    func createSymbolicLink(at destination: VFSPath, withDestination target: String) throws

    /// Copy just the metadata (permissions, timestamps, extended attributes) from
    /// `source` onto an already-created `destination` — used to finish a directory that
    /// the engine had to recreate by hand on the cross-volume fallback path. The default
    /// is a no-op so a backend that doesn't track metadata compiles untouched.
    func copyMetadata(at source: VFSPath, to destination: VFSPath) throws

    /// The same, told what the source carried — so a remote backend finishing a directory it
    /// recreated by hand does not spend a round trip asking (PLAN.md §M25 Slice 2).
    ///
    /// The engine calls this holding the very `FileEntry` it listed, so the hint is free where a
    /// `stat` would be a whole connection. Additive with a forwarding default, exactly as
    /// ``copyFile(at:to:expectedSize:sourceMetadata:progress:isCancelled:)`` is.
    func copyMetadata(
        at source: VFSPath,
        to destination: VFSPath,
        sourceMetadata: RemoteSourceMetadata?
    ) throws

    /// What this backend's connection has failed to carry so far, for the path's account (PLAN.md
    /// §M25 Slice 5b).
    ///
    /// A **running count**, not an event: a caller learns what one job lost by reading this before
    /// and after and subtracting (``RemoteMetadataTally/since(_:)``). That shape rather than a drain
    /// because a drain has to be called exactly once by exactly one caller and nothing enforces it,
    /// where two readings can be taken by anybody in any order.
    ///
    /// It takes a path for the same reason ``editableMetadata(at:)`` does — a routing backend
    /// answers for whoever owns the row — and it matters more here: a job with ends on two accounts
    /// must add up *those* accounts' deltas, and a job running concurrently on a third must not be
    /// counted into it. A single process-wide reading would do exactly that, and it would fail in
    /// the quiet direction: one copy reporting another's loss.
    ///
    /// The default is zero, which is the true answer for the local disk, an archive and an object
    /// store alike — none of them can lose a mode or a date on the way.
    func metadataTally(at path: VFSPath) -> RemoteMetadataTally

    /// Which of a remote item's fields Get Info may **change** on this connection (PLAN.md §M25
    /// Slice 5).
    ///
    /// Asked of the backend rather than derived from the protocol, because it is a fact about one
    /// *account*: a server that has refused `SITE CHMOD` once has answered for every later file, and
    /// `RemoteMetadataSupport` is where that answer is remembered. Reading it here is what lets the
    /// panel offer a control only where pressing Save can do something — the alternative being a
    /// control that looks live and is refused every time.
    ///
    /// It takes a path because a routing backend answers for whoever owns the row, not for itself:
    /// a results tab holds hits from anywhere and a tree draws several connections at once, which is
    /// the per-row rule `AttributesRoute` already settled for the read half.
    ///
    /// The default is empty — nothing is editable — so a backend that has not implemented the write
    /// verbs shows exactly the read-only panel M24 Slice 7 shipped.
    func editableMetadata(at path: VFSPath) -> RemoteMetadataCapabilities

    /// Write an item's mode or modification time, answering the steps that did not take.
    ///
    /// It **answers** rather than throwing for a refused step, the same rule
    /// ``RemoteWriteTransport/applyMetadata(_:to:)`` follows: a server that will not keep a mode has
    /// not failed the operation, and a caller has to be able to tell "the connection broke" from
    /// "the server said no" in order to word either one. Throwing stays for the connection itself.
    ///
    /// Note what the answer is *not*: proof that everything else landed. A clean answer here is
    /// necessary and not sufficient, because `sftp`'s `chmod` reports success for a mode the server
    /// did not store — so the caller weighs it against a re-read (``RemoteAttributeVerdict``).
    ///
    /// The default refuses, naming the item, so a backend with no write verbs cannot silently report
    /// a change it never made.
    func applyMetadata(
        _ steps: [RemoteMetadataStep],
        at path: VFSPath
    ) throws -> [RemoteMetadataRefusal]

    /// Fill in the symlink **targets** of whichever of `entries` arrived without one, for a backend
    /// that can learn them at a price a *listing* should not pay (PLAN.md §M25 Slice 4).
    ///
    /// A listing carries a target wherever reading it is free — the local disk `readlink`s as part
    /// of its `stat`, an archive's table of contents prints one, FTP's `LIST` prints one — and
    /// `sftp`'s does not, because the protocol has no verb for it. Over SFTP the answer costs a
    /// whole SSH exec channel, which is 77 ms against a *loopback* server and a real round trip over
    /// a network, so making every browse pay it to render a column almost nobody reads would be the
    /// wrong trade. Asking here instead means only an operation that has to **recreate** a link pays,
    /// and only when there is one.
    ///
    /// It takes a batch and not a path for the reason the price is what it is: the cost measured is
    /// the connection, not the row — twelve links in one command cost 79 ms against 77 ms for one —
    /// so a per-path seam would turn a directory of links into a directory of round trips. Callers
    /// should hand over everything they are about to walk.
    ///
    /// **It cannot fail**, and that is deliberate: a backend that could not find out returns the
    /// entries it was given, still carrying `nil`, and the caller refuses that item on its own terms
    /// (``VFSUnsupportedReason/symbolicLinkTargetUnreadable(name:)``). An account with no exec
    /// channel is a healthy account, so this degrades the way §M22's search walk does rather than
    /// raising anything.
    ///
    /// The default returns `entries` untouched, so every backend whose listing already answers —
    /// which is all of them but SFTP — behaves exactly as it always did.
    func resolvingSymlinkTargets(in entries: [FileEntry]) -> [FileEntry]

    /// Whether a copy with **both ends inside this backend** is worth attempting here, even though
    /// the attempt may be refused (PLAN.md §M25 Slice 3).
    ///
    /// Not the same question as ``VFSCapabilities/internalCopy``, and the difference is the whole
    /// reason it is a method rather than another bit. A capability is a *promise* a router acts on
    /// with no fallback; this is an *attempt* whose refusal is a fact about one server that nothing
    /// can ask in advance — OpenSSH's `copy-data` extension is either advertised or it is not, and
    /// the only way to learn which is to send `cp` and read what comes back. So a router that gets
    /// `true` here must be ready to move the bytes itself (``RelayCopy``), and a backend that
    /// answers `true` must latch the refusal so the next file does not pay to find out again.
    ///
    /// The default is `false`: a backend that has no such verb is asked nothing and behaves exactly
    /// as it always did.
    func mayAttemptInternalCopy(from source: VFSPath, to destination: VFSPath) -> Bool

    /// A stable identifier for the physical volume `path` resides on, or `nil` when the
    /// backend can't tell its volumes apart. The M2 operation queue schedules by this:
    /// jobs that share a volume run serially (so two transfers don't thrash one disk
    /// head), while jobs on independent volumes run concurrently (PLAN.md §2
    /// "serial-per-volume scheduling").
    ///
    /// Two paths on the same volume must return equal, non-`nil` identifiers, and it must
    /// be cheap — the queue may call it for every source of every job on the actor, so an
    /// implementation should not touch the network or do heavy I/O. The default returns
    /// `nil`, which the queue reads as "one indistinguishable volume", so a backend that
    /// opts out simply has all its jobs serialized (the safe choice).
    func volumeIdentifier(for path: VFSPath) -> String?
}
