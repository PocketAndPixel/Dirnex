import Foundation

/// A single queued file operation: move a set of source entries into a destination
/// directory, by copy or move (PLAN.md §2 "Operations"). The "instant" operations
/// (new folder, delete) don't need this shape — they finish immediately and live in
/// the `VFSBackend` write primitives; this models the byte-moving work that the
/// `CopyEngine` runs with progress, cancellation, and conflict handling.
public struct FileOperation: Sendable {
    public enum Kind: Sendable, Equatable {
        /// Duplicate the sources into the destination, leaving the originals in place.
        case copy
        /// Relocate the sources into the destination — a same-volume rename where
        /// possible, else a copy-then-delete across volumes.
        case move
    }

    public let kind: Kind
    public let sources: [FileEntry]
    public let destinationDirectory: VFSPath

    public init(kind: Kind, sources: [FileEntry], destinationDirectory: VFSPath) {
        self.kind = kind
        self.sources = sources
        self.destinationDirectory = destinationDirectory
    }
}

/// What to do when a source's destination is already occupied. A single policy can be
/// fixed for the whole operation, or `ask` can hand each conflict to a resolver so the
/// app can raise its rich per-file dialog and remember an "apply to all" choice.
public enum ConflictPolicy: Sendable, Equatable {
    /// Treat any existing destination as a per-item failure — the safe default, so a
    /// caller that forgets to resolve conflicts never silently clobbers data.
    case fail
    /// Leave the existing item untouched and skip the colliding source.
    case skip
    /// Replace the existing item. The new copy is written to a temporary sibling first
    /// and swapped into place, so the original survives until the replacement is
    /// complete (a half-finished copy never destroys the file it was replacing).
    case overwrite
    /// Replace the existing item only when the source is strictly newer than it (by
    /// modification date); an equal-or-older source is skipped, like the existing one is
    /// kept. This is TC's "overwrite older" — the safe way to fold newer edits into a
    /// destination without touching files that are already up to date. The comparison is
    /// on the top-level item's own modification date, so a directory is replaced wholesale
    /// when *its* mtime is newer (a per-file merge is a later pass — see PLAN.md §M2).
    case newerOnly
    /// Copy the source under a fresh, non-colliding name ("file copy.txt", "file copy 2.txt").
    case keepBoth
    /// Hand each conflict to the operation's resolver as the engine reaches it — the mode
    /// behind TC's per-file conflict dialog with "apply to all". The engine blocks on the
    /// resolver (the caller runs on a background task, so it can bridge to a main-actor
    /// prompt), then acts on the returned `ConflictResolution`. Falls back to `fail` when
    /// no resolver was supplied. See `CopyEngine.run(resolveConflict:)`.
    case ask
}

/// One conflict handed to an `ask`-policy resolver: the source about to be written and the
/// item already sitting at its destination, so the app can show a side-by-side comparison
/// (names, sizes, dates, thumbnails) before deciding. Delivered synchronously on the
/// engine's copy thread; the resolver may block it while a prompt is on screen.
public struct ConflictContext: Sendable, Equatable {
    /// Whether the operation is a copy or a move, for the dialog's wording.
    public let kind: FileOperation.Kind
    /// The item being transferred in.
    public let source: FileEntry
    /// The item already occupying the destination path.
    public let existing: FileEntry

    public init(kind: FileOperation.Kind, source: FileEntry, existing: FileEntry) {
        self.kind = kind
        self.source = source
        self.existing = existing
    }
}

/// One conflict's answer from an `ask`-policy resolver — the per-conflict analogue of a
/// `ConflictPolicy`, plus `cancel` to abort the whole operation from the dialog.
public enum ConflictResolution: Sendable, Equatable {
    /// Replace the existing item (atomic temp-swap, like `ConflictPolicy.overwrite`).
    case overwrite
    /// Replace only if the source is strictly newer (like `ConflictPolicy.newerOnly`).
    case overwriteIfNewer
    /// Leave the existing item and skip this source.
    case skip
    /// Transfer under a fresh non-colliding name (like `ConflictPolicy.keepBoth`).
    case keepBoth
    /// Stop the whole operation now, leaving already-completed items in place — the engine
    /// reports it as cancelled, exactly like a mid-copy cancel.
    case cancel
}

/// One item's error handed to `CopyEngine.run(onError:)` when a source can't be transferred —
/// the hook behind TC's per-file "Skip / Retry / Abort" error dialog. Delivered synchronously
/// on the engine's copy thread (like `ConflictContext`), so the resolver may block it while a
/// prompt is on screen. A missing resolver means the engine keeps its default behaviour:
/// collect the failure and carry on to the remaining sources.
public struct OperationErrorContext: Sendable, Equatable {
    /// Whether the operation is a copy or a move, for the dialog's wording.
    public let kind: FileOperation.Kind
    /// The source that failed to transfer.
    public let path: VFSPath
    /// Why it failed — the same `VFSError` the report would otherwise collect.
    public let error: VFSError

    public init(kind: FileOperation.Kind, path: VFSPath, error: VFSError) {
        self.kind = kind
        self.path = path
        self.error = error
    }
}

/// One failed item's answer from an `onError` resolver — TC's "Skip / Retry / Abort".
public enum ErrorResolution: Sendable, Equatable {
    /// Try the same source again from scratch (any partially-copied bytes are discarded
    /// first). The engine keeps re-attempting as long as the resolver keeps asking to retry.
    case retry
    /// Record the failure and move on to the next source — the engine's default when no
    /// resolver is supplied, so an unattended run still finishes and summarizes.
    case skip
    /// Stop the whole operation now, leaving already-completed items in place. Reported as
    /// cancelled, exactly like a mid-copy cancel or a conflict `.cancel`.
    case abort
}

/// A live snapshot of an operation's progress, delivered to the caller's progress UI.
/// `totalBytes` is measured up front (a directory pre-scan) so the bar is determinate
/// and an ETA is possible; it is `0` only when the source set is genuinely empty.
public struct OperationProgress: Sendable, Equatable {
    public let totalBytes: Int64
    public let completedBytes: Int64
    public let totalItems: Int
    public let completedItems: Int
    /// The top-level source currently being transferred, for the "Copying X…" label.
    public let currentItem: VFSPath?

    public init(
        totalBytes: Int64,
        completedBytes: Int64,
        totalItems: Int,
        completedItems: Int,
        currentItem: VFSPath?
    ) {
        self.totalBytes = totalBytes
        self.completedBytes = completedBytes
        self.totalItems = totalItems
        self.completedItems = completedItems
        self.currentItem = currentItem
    }

    /// Fraction complete in `0...1`, or `0` before any bytes are known.
    public var fraction: Double {
        totalBytes > 0 ? min(1, Double(completedBytes) / Double(totalBytes)) : 0
    }
}

/// One source's failure during an operation, in a `Sendable` shape so it can cross back
/// from the background task. A failure lands here only when the run's `onError` resolver
/// (or its absence) settles on `.skip`; `.retry` re-attempts and `.abort` unwinds the whole
/// operation instead (PLAN.md §M2 "per-file skip/retry/abort"). Collected failures are
/// summarized at the end, never as a modal storm.
public struct OperationItemFailure: Sendable, Equatable {
    public let path: VFSPath
    public let error: VFSError

    public init(path: VFSPath, error: VFSError) {
        self.path = path
        self.error = error
    }
}

/// What became of one top-level source once the engine finished with it — the record the
/// undo journal reverses (PLAN.md §M2 "Cmd+Z reverses move/rename/copy"). The engine knows
/// exactly where each item landed (including the fresh name a keep-both copy took) and
/// whether it replaced something already there, so the undo layer never has to re-derive it.
public struct OperationItemOutcome: Sendable, Equatable {
    public let source: VFSPath
    /// Where the item now lives — the copy's/move's landing path. `nil` when the conflict
    /// policy skipped the item, so nothing happened and there is nothing to reverse.
    public let landedAt: VFSPath?
    /// The landing path was already occupied and got overwritten. Such an item can't be
    /// cleanly reversed (the replaced original is gone), so undo reports it rather than
    /// silently deleting the replacement — see `UndoRecord.transfer`.
    public let replacedExisting: Bool

    public init(source: VFSPath, landedAt: VFSPath?, replacedExisting: Bool) {
        self.source = source
        self.landedAt = landedAt
        self.replacedExisting = replacedExisting
    }
}

/// The outcome of running an operation: what got through, what was skipped by the
/// conflict policy, what failed, and whether the user cancelled partway.
public struct OperationReport: Sendable, Equatable {
    public let completedItems: Int
    public let completedBytes: Int64
    public let skipped: [VFSPath]
    public let failures: [OperationItemFailure]
    public let wasCancelled: Bool
    /// Per-item disposition for the sources that completed, in the order they finished —
    /// the raw material the undo journal turns into a reversal (see `UndoRecord.transfer`).
    public let outcomes: [OperationItemOutcome]

    public init(
        completedItems: Int,
        completedBytes: Int64,
        skipped: [VFSPath],
        failures: [OperationItemFailure],
        wasCancelled: Bool,
        outcomes: [OperationItemOutcome] = []
    ) {
        self.completedItems = completedItems
        self.completedBytes = completedBytes
        self.skipped = skipped
        self.failures = failures
        self.wasCancelled = wasCancelled
        self.outcomes = outcomes
    }

    public var succeeded: Bool { failures.isEmpty && !wasCancelled }
}
