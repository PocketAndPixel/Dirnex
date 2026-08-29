/// A single queued file operation (PLAN.md §2 "Operations"). The "instant" operations
/// (new folder, delete) don't need this shape — they finish immediately and live in
/// the `VFSBackend` write primitives; this models the long, byte-touching work that runs
/// with progress, cancellation, and a place in the queue bar.
public struct FileOperation: Sendable {
    public enum Kind: Sendable, Equatable {
        /// Duplicate the sources into the destination, leaving the originals in place.
        case copy
        /// Relocate the sources into the destination — a same-volume rename where
        /// possible, else a copy-then-delete across volumes.
        case move
        /// Hash bytes rather than move them — write a checksum manifest, or verify one
        /// (PLAN.md §M14 Slice 2). The first kind that produces no `outcomes` and nothing
        /// to undo; its answer rides home on ``OperationReport/checksum``.
        ///
        /// It is here rather than in a queue of its own because everything the queue offers is
        /// exactly what hashing needs: one job per volume so two runs don't thrash the same disk,
        /// pause, cancel, and a determinate bar. A 50 GB SHA-256 is ~25 s and a CRC32 of the same
        /// file ~100 s, so "run it modally and hope" was never available.
        case checksum(ChecksumJob)
        /// Change metadata rather than move bytes — apply an attributes patch (and optionally an
        /// ACL) to the sources and everything inside them (PLAN.md §M14 Slice 4).
        ///
        /// The *flat* case never comes here: one item, or a marked set, is a handful of syscalls
        /// that finish before the sheet closes. Recursion is the shape that can run over a hundred
        /// thousand items and the one that can wreck a tree, so it gets the same determinate bar,
        /// pause and cancel a copy gets — and, like `.checksum`, it needs no scheduler of its own.
        ///
        /// Unlike every other kind it produces no `outcomes`, because there is nothing to move:
        /// its answer, *including the undo material*, rides home on
        /// ``OperationReport/attributeApply``.
        case attributes(AttributeApplyJob)
        /// Write an encrypted archive from the sources (PLAN.md §M19 Slice 2).
        ///
        /// Only the *encrypted* path comes here — every other format is still one `bsdtar` spawn on
        /// the caller's own thread. The split is not tidiness: the reason M19 links libarchive at
        /// all is that `bsdtar` cannot be handed a passphrase without putting it in `argv`, and the
        /// reason this work needs a queue is that AES-256 over a folder of photographs is minutes
        /// during which the user must be able to change their mind. A `.tar.gz` has neither problem.
        ///
        /// Like `.checksum` and `.attributes` it produces no `outcomes` — there is nothing to move,
        /// so nothing to undo — and its answer rides home on ``OperationReport/pack``.
        case pack(PackJob)
        /// Write an **unencrypted** archive from the sources — every format `bsdtar` knows
        /// (PLAN.md §4 ▸ *Smaller than a milestone*).
        ///
        /// A second kind rather than a field on ``pack(_:)`` because the two write through
        /// different machinery: libarchive linked into this process, which can take a passphrase
        /// and can only write zip, against a `bsdtar` spawn, which can write every format and
        /// cannot be handed a passphrase safely. ``PlainPackJob`` says the rest.
        ///
        /// It came to the queue on 2026-08-30, two milestones after its encrypted twin, and for the
        /// half of the work the split never covered: a pack bound for a server has an upload, and
        /// the upload had no bar and no Stop. Like `.pack` it produces no `outcomes` and rides its
        /// answer home on ``OperationReport/pack``.
        case plainPack(PlainPackJob)
        /// Pull a set of rows that are not on this disk down to real paths, so a gesture that only
        /// speaks in paths can run over them (PLAN.md §M24 Slice 2).
        ///
        /// Moves bytes like a copy and is deliberately **not** one: its destination is a temp root,
        /// so it produces no `outcomes` and there is nothing to undo — reversing it would mean
        /// putting back a copy the user never saw. That is also why it is not expressed as a `.copy`
        /// into that root, which `UndoJournal` would dutifully record as a transfer.
        ///
        /// No payload, unlike the three kinds above it: `destinationDirectory` already means "where
        /// this job puts things", and the only other thing the runner needs — which rows — is
        /// `sources`. What the set is *for* stays with the gesture, along with the decision, made
        /// before anything was queued, that the total was worth spending (`MaterializationPlan`).
        case materialize
    }

    public let kind: Kind
    public let sources: [FileEntry]
    public let destinationDirectory: VFSPath

    /// The name the single source lands under, when this job is a **rename** the backend could not
    /// perform in place. `nil` — every other job — lands each source under its own name.
    ///
    /// It is a field on a `.move` rather than a `Kind` of its own because a rename that reaches the
    /// queue *is* a move: the only reason it is here is that the backend answered `EXDEV`, which is
    /// exactly the signal ``CopyEngine`` already turns into a recursive copy-then-delete. A
    /// `.rename` kind would fork every `switch` over ``Kind`` — four label sites in the app, the
    /// undo journal's label map, and `CopyEngine`'s own `kind == .move` tests — to change a caption
    /// on a job whose behavior is identical. What the user is told about the difference belongs in
    /// the confirmation that raised it, which is where the app says it.
    ///
    /// Only ``init(renaming:to:in:)`` sets it, so "several sources under one new name" is
    /// unrepresentable rather than merely undocumented.
    public let renamedTo: String?

    /// Which file on this disk stands for each row that was not already on it (PLAN.md §M24
    /// Slice 4). Empty for every job over ordinary local files, which is the common case and the
    /// default.
    ///
    /// A field on the operation rather than on a `Kind`'s payload, because it is one fact about how
    /// this job **reads** bytes and not a fact about what the job *is*: a checksum, a user script
    /// and a pack each want the same answer, and the kinds that move bytes themselves have no use
    /// for it at all.
    ///
    /// It is deliberately not derived from ``sources``. A verification's rows are discovered by
    /// walking the manifest's own directory, so the set that needs standing in for is not the set
    /// the job was handed — and a map keyed to `sources` would be right only for whichever gesture
    /// happened to be written first.
    public let materialized: MaterializedPaths

    public init(
        kind: Kind,
        sources: [FileEntry],
        destinationDirectory: VFSPath,
        materialized: MaterializedPaths = MaterializedPaths()
    ) {
        self.kind = kind
        self.sources = sources
        self.destinationDirectory = destinationDirectory
        self.materialized = materialized
        renamedTo = nil
    }

    /// A rename that has to run as a job: `source` keeps its directory and takes `newName`.
    ///
    /// The caller reaches for this only after ``VFSBackend/moveItem(at:to:)`` has refused with
    /// `EXDEV` — an S3 prefix today, since a "folder" there is N objects and renaming it is N
    /// server-side copies and N deletes. Everything that makes that bearable is the queue's
    /// already: a determinate bar, Stop, the conflict policy, per-item failures, and an undo
    /// record built from the outcomes.
    public init(renaming source: FileEntry, to newName: String, in directory: VFSPath) {
        kind = .move
        sources = [source]
        destinationDirectory = directory
        materialized = MaterializedPaths()
        renamedTo = newName
    }

    /// The name `entry` lands under in ``destinationDirectory`` — its own, unless this job is a
    /// rename. The one place the distinction is read, so a second spelling cannot drift from it.
    public func landingName(for entry: FileEntry) -> String {
        renamedTo ?? entry.name
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
    /// reports it as canceled, exactly like a mid-copy cancel.
    case cancel
}

/// One item's error handed to `CopyEngine.run(onError:)` when a source can't be transferred —
/// the hook behind TC's per-file "Skip / Retry / Abort" error dialog. Delivered synchronously
/// on the engine's copy thread (like `ConflictContext`), so the resolver may block it while a
/// prompt is on screen. A missing resolver means the engine keeps its default behavior:
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
    /// canceled, exactly like a mid-copy cancel or a conflict `.cancel`.
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
/// conflict policy, what failed, and whether the user canceled partway.
public struct OperationReport: Sendable, Equatable {
    public let completedItems: Int
    public let completedBytes: Int64
    public let skipped: [VFSPath]
    public let failures: [OperationItemFailure]
    public let wasCancelled: Bool
    /// Per-item disposition for the sources that completed, in the order they finished —
    /// the raw material the undo journal turns into a reversal (see `UndoRecord.transfer`).
    public let outcomes: [OperationItemOutcome]
    /// What a `.checksum` job produced — the digests it wrote, or its verdict on a manifest.
    /// `nil` for every other kind.
    ///
    /// The answer rides home on the report rather than through a completion closure so it arrives
    /// by the one path the app already watches: `FileOperationQueue`'s snapshot stream, where the
    /// window already notices a job reaching a terminal state. A second result channel would be a
    /// second place for a finished job to be missed.
    public let checksum: ChecksumOutcome?

    /// What a recursive `.attributes` job changed, and whether it is small enough to undo. `nil` for
    /// every other kind. Rides home on the report for the same reason `checksum` does — and this one
    /// carries the *undo material*, so a second channel would be a second place to lose a tree's
    /// only way back.
    public let attributeApply: AttributeApplyOutcome?

    /// What a `.pack` job wrote, or why it wrote nothing. `nil` for every other kind. Rides home on
    /// the report for the same reason the two above it do — the queue's snapshot stream is the one
    /// path the window already watches for a job reaching a terminal state.
    public let pack: PackOutcome?

    /// What this job could not carry besides bytes, or `nil` when it carried everything it was asked
    /// to — which is every local copy and the great majority of remote ones (PLAN.md §M25 Slice 5b).
    ///
    /// A **per-job** answer, not a per-connection one: it is the difference between what each
    /// account this job touched had already failed to carry when the job started and what it has
    /// failed to carry now. The distinction is the whole point — the accumulator behind it spans a
    /// connection's whole life, so reporting *that* would tell a user about their previous transfer
    /// every time.
    ///
    /// It rides home on the report for the reason `checksum`, `pack` and `materialized` do: the
    /// queue's snapshot stream is the one path the window already watches for a job reaching a
    /// terminal state, and a second result channel would be a second place for a finished job to be
    /// missed.
    public let metadataLoss: RemoteMetadataLoss?

    /// Where a `.materialize` job's bytes landed, one entry per row that made it. `nil` for every
    /// other kind, and **empty for a materialize that landed nothing** — the two are different
    /// answers and a caller reading the copies has to be able to tell them apart.
    ///
    /// No outcome wrapper, unlike its three neighbours, because there is nothing else to say: the
    /// failures ride on ``failures`` where every other kind's per-path failures already do, and a
    /// struct holding one array would be a type whose only field is the answer.
    public let materialized: [MaterializedFile]?

    public init(
        completedItems: Int,
        completedBytes: Int64,
        skipped: [VFSPath],
        failures: [OperationItemFailure],
        wasCancelled: Bool,
        outcomes: [OperationItemOutcome] = [],
        checksum: ChecksumOutcome? = nil,
        attributeApply: AttributeApplyOutcome? = nil,
        pack: PackOutcome? = nil,
        materialized: [MaterializedFile]? = nil,
        metadataLoss: RemoteMetadataLoss? = nil
    ) {
        self.completedItems = completedItems
        self.completedBytes = completedBytes
        self.skipped = skipped
        self.failures = failures
        self.wasCancelled = wasCancelled
        self.outcomes = outcomes
        self.checksum = checksum
        self.attributeApply = attributeApply
        self.pack = pack
        self.materialized = materialized
        self.metadataLoss = metadataLoss
    }

    public var succeeded: Bool { failures.isEmpty && !wasCancelled }

    /// A report for a job that did nothing — the safe answer when a dispatch cannot match a kind,
    /// so a routing bug degrades to "nothing happened" rather than a trap.
    public static let empty = OperationReport(
        completedItems: 0,
        completedBytes: 0,
        skipped: [],
        failures: [],
        wasCancelled: false
    )
}
