import Foundation

/// What a backend can do. Panels grey out operations a backend lacks
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
    /// The backend can't delete at all — the operation is greyed out.
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
/// default implementations throw `.unsupported`, and the panel greys the operation
/// out via `capabilities` (PLAN.md §M5 "capability degradation").
public protocol VFSBackend: Sendable {
    var id: VFSBackendID { get }
    var capabilities: VFSCapabilities { get }

    /// The capabilities that apply to `path` specifically. Single-backend implementations
    /// return their backend-wide `capabilities` (the default), but a *routing* backend that
    /// composes several concrete backends (the app's `CompositeBackend`) overrides this to
    /// report the capabilities of whichever backend owns `path` — so a panel greys out
    /// operations per the *current* location's backend, not the composite's primary
    /// (PLAN.md §M5 "panels grey out unsupported ops per backend").
    func capabilities(for path: VFSPath) -> VFSCapabilities

    /// List the immediate children of `path` (excluding `.` and `..`), unsorted.
    /// Throws `VFSError.notADirectory` if `path` is a file.
    func listDirectory(at path: VFSPath) throws -> [FileEntry]

    /// Stat a single entry (does not follow the entry itself if it is a symlink).
    func stat(at path: VFSPath) throws -> FileEntry

    /// Create a single directory at `path`. Throws `.alreadyExists` if something is
    /// already there and `.notFound` if the parent does not exist (no intermediate
    /// directories are created — mirrors `mkdir(2)`).
    func createDirectory(at path: VFSPath) throws

    /// Create an empty regular file at `path`. Throws `.alreadyExists` if anything is already
    /// there — deliberately never truncating, because the one caller is ⇧F4 "Edit File…", where
    /// an existing name means *open that file* and silently emptying it would destroy the very
    /// document the user was reaching for (PLAN.md §M11).
    func createFile(at path: VFSPath) throws

    /// Move or rename `source` to `destination` within this backend. Same-volume moves
    /// are an atomic rename; a cross-volume move throws (the operation engine falls back
    /// to copy-then-delete). Throws `.alreadyExists` if `destination` is occupied.
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

    /// Recreate a symbolic link at `destination` pointing at the raw (unresolved) target
    /// text `target`. Copying a symlink duplicates the link itself, never the file it
    /// points at (matching `clonefile`/`cp -R` semantics).
    func createSymbolicLink(at destination: VFSPath, withDestination target: String) throws

    /// Copy just the metadata (permissions, timestamps, extended attributes) from
    /// `source` onto an already-created `destination` — used to finish a directory that
    /// the engine had to recreate by hand on the cross-volume fallback path. The default
    /// is a no-op so a backend that doesn't track metadata compiles untouched.
    func copyMetadata(at source: VFSPath, to destination: VFSPath) throws

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

public extension VFSBackend {
    func capabilities(for path: VFSPath) -> VFSCapabilities {
        capabilities // a single-backend implementation is uniform across all its paths
    }

    func createDirectory(at path: VFSPath) throws {
        throw VFSError.unsupported(.createDirectory)
    }

    func createFile(at path: VFSPath) throws {
        throw VFSError.unsupported(.createFile)
    }

    func moveItem(at source: VFSPath, to destination: VFSPath) throws {
        throw VFSError.unsupported(.moveItem)
    }

    func removeItem(at path: VFSPath) throws {
        throw VFSError.unsupported(.removeItem)
    }

    @discardableResult
    func trashItem(at path: VFSPath) throws -> VFSPath? {
        throw VFSError.unsupported(.trash)
    }

    func cloneItem(at source: VFSPath, to destination: VFSPath) throws -> Bool {
        false // no copy-on-write here — the engine falls back to a chunked copy
    }

    func copyFile(
        at source: VFSPath,
        to destination: VFSPath,
        progress: (Int64) -> Void,
        isCancelled: () -> Bool
    ) throws {
        throw VFSError.unsupported(.copyFile)
    }

    func createSymbolicLink(at destination: VFSPath, withDestination target: String) throws {
        throw VFSError.unsupported(.symbolicLink)
    }

    func copyMetadata(at source: VFSPath, to destination: VFSPath) throws {
        // Backends without metadata to preserve need do nothing.
    }

    func volumeIdentifier(for path: VFSPath) -> String? {
        nil // "one indistinguishable volume" — the queue serializes such a backend's jobs
    }
}
