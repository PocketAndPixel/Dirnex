import Foundation

/// Executes a `FileOperation` (copy or move) against a backend, reporting progress and
/// honoring cancellation — TC's queued, non-blocking file operations (PLAN.md §M2).
///
/// It lives in `DirnexCore` because it touches bytes ("if it touches bytes, it lives in
/// DirnexCore and has tests" — §2) and is a plain synchronous entry point: the caller
/// decides where it runs (the app hands it a detached background task and marshals the
/// progress callbacks to the main actor). Each source is transferred with the fastest
/// path the backend offers — an APFS clone of the whole subtree same-volume, a chunked
/// recursive copy across volumes — so a same-disk copy is instant and a cross-disk copy
/// still streams with progress.
public enum CopyEngine {
    /// Run `operation`, returning a report of what completed, was skipped, or failed.
    ///
    /// - `conflictPolicy` is applied to every top-level source whose destination already
    ///   exists; non-colliding sources ignore it.
    /// - `resolveConflict` is consulted for each conflict when `conflictPolicy` is `.ask` —
    ///   the hook behind TC's per-file dialog. It is called synchronously on the copy
    ///   thread (never for a non-colliding source), so the caller may block it while a
    ///   prompt is on screen; returning `.cancel` aborts the whole operation. With any
    ///   other policy it is ignored, and an `.ask` policy with no resolver behaves as `.fail`.
    /// - `onError` is consulted whenever a source fails to transfer — the hook behind TC's
    ///   per-file "Skip / Retry / Abort" dialog. Like `resolveConflict` it runs synchronously
    ///   on the copy thread, so the caller may block it: `.retry` re-attempts the same source
    ///   (discarding any partial bytes first), `.skip` collects the failure and moves on, and
    ///   `.abort` unwinds the whole operation as canceled. A missing resolver behaves as
    ///   `.skip`, so an unattended run still finishes and summarizes its failures.
    /// - `onProgress` is called periodically: at each top-level item boundary, and otherwise once
    ///   8 MiB have moved or a tenth of a second has passed, whichever comes first — never per
    ///   chunk or per file, so a 50 GB copy or a folder of 100 000 small files doesn't flood the
    ///   caller. The clock is what names a small file (PLAN.md §M41): bytes alone left a folder of
    ///   3 000 small files unnamed. Each update carries ``OperationProgress/files``.
    /// - `isCancelled` is polled between chunks and items; canceling leaves a report with
    ///   `wasCancelled == true` and cleans up any half-written file. A partially copied
    ///   directory tree is left in place, with the files that finished, and named in
    ///   ``OperationReport/stoppedPartway`` so that undo can remove it.
    /// - `uptime` is the clock behind that tenth of a second, in seconds from any fixed point.
    ///   Injectable so a test can make every file start report, or none.
    public static func run(
        _ operation: FileOperation,
        using backend: any VFSBackend,
        conflictPolicy: ConflictPolicy = .fail,
        resolveConflict: (@Sendable (ConflictContext) -> ConflictResolution)? = nil,
        onError: (@Sendable (OperationErrorContext) -> ErrorResolution)? = nil,
        onProgress: @escaping @Sendable (OperationProgress) -> Void = { _ in },
        isCancelled: @escaping @Sendable () -> Bool = { false },
        uptime: @escaping @Sendable () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }
    ) -> OperationReport {
        CopyRun(
            operation: operation,
            backend: backend,
            policy: conflictPolicy,
            resolveConflict: resolveConflict,
            onError: onError,
            tally: CopyProgressTally(
                totalItems: operation.sources.count,
                onProgress: onProgress,
                uptime: uptime
            ),
            isCancelled: isCancelled
        ).execute()
    }
}

/// One execution of a `FileOperation`. A short-lived class (never shared across tasks)
/// so the recursive copy and its helpers can share a running tally (``CopyProgressTally``)
/// without threading `inout` accumulators through every call.
private final class CopyRun {
    /// One top-level source with what the pre-scan measured under it.
    private struct SizedSource {
        let entry: FileEntry
        let bytes: Int64
        /// Files at any depth (``DirectorySizeMeasurement/files``); a non-directory source is one.
        let files: Int
    }

    private let operation: FileOperation
    private let backend: any VFSBackend
    private let policy: ConflictPolicy
    private let resolveConflict: (@Sendable (ConflictContext) -> ConflictResolution)?
    private let onError: (@Sendable (OperationErrorContext) -> ErrorResolution)?
    private let isCancelled: @Sendable () -> Bool

    private var tally: CopyProgressTally
    private var skipped: [VFSPath] = []
    private var failures: [OperationItemFailure] = []
    private var outcomes: [OperationItemOutcome] = []
    /// The source a Stop caught partway, with what of it was left (``OperationReport/stoppedPartway``).
    private var stoppedPartway: OperationItemOutcome?
    /// What each account this job touches had already failed to carry when the job started
    /// (PLAN.md §M25 Slice 5b).
    ///
    /// Taken once, up front, because the answer this job owes is a **difference**: the accumulator
    /// on a connection spans that connection's whole life, and a user told "the modification times
    /// weren't kept" after their second transfer must not be being told about their first.
    ///
    /// Keyed per backend rather than summed into one number, and that is what keeps it correct under
    /// the queue's own scheduling: jobs on *one* account serialize (they share a volume bucket), but
    /// a job on account A runs happily beside one on account B — so a single process-wide reading
    /// would fold B's losses into A's report. Quietly, and in the direction this milestone exists to
    /// avoid.
    private var startingTallies: [VFSBackendID: RemoteMetadataTally] = [:]

    init(
        operation: FileOperation,
        backend: any VFSBackend,
        policy: ConflictPolicy,
        resolveConflict: (@Sendable (ConflictContext) -> ConflictResolution)?,
        onError: (@Sendable (OperationErrorContext) -> ErrorResolution)?,
        tally: CopyProgressTally,
        isCancelled: @escaping @Sendable () -> Bool
    ) {
        self.operation = operation
        self.backend = backend
        self.policy = policy
        self.resolveConflict = resolveConflict
        self.onError = onError
        self.tally = tally
        self.isCancelled = isCancelled
    }

    func execute() -> OperationReport {
        startingTallies = metadataTallies()
        let sized = preScan()
        tally.begin(
            totalBytes: sized.reduce(0) { $0 + $1.bytes },
            totalFiles: sized.reduce(0) { $0 + $1.files }
        )

        for item in sized {
            if isCancelled() { return report(canceled: true) }
            if !transfer(item) {
                return report(canceled: true) // canceled mid-item
            }
        }
        return report(canceled: false)
    }

    // MARK: - Pre-scan

    /// Measure each source's byte weight and file count up front for the progress denominators,
    /// reusing the directory sizer for subtrees. A source we can't size counts as 0 bytes and no
    /// files rather than aborting the whole operation.
    private func preScan() -> [SizedSource] {
        // A marked symlink may have arrived from a listing that could not say what it points at, and
        // recreating it needs that text. Asking here costs nothing when there are no links and one
        // round trip when there are (PLAN.md §M25 Slice 4).
        backend.resolvingSymlinkTargets(in: operation.sources).map { entry in
            guard entry.kind == .directory else {
                return SizedSource(entry: entry, bytes: entry.byteSize, files: 1)
            }
            let measured = try? DirectorySizer.measure(
                of: entry.path,
                using: backend,
                isCancelled: isCancelled
            )
            return SizedSource(
                entry: entry,
                bytes: measured?.bytes ?? 0,
                files: measured?.files ?? 0
            )
        }
    }

    // MARK: - Per-item transfer

    /// Transfer one top-level source, applying the conflict policy. Returns `false` only
    /// when the operation should unwind (a user cancel or an `onError` `.abort`); item-level
    /// failures are recorded and reported as `true` so the operation carries on to the
    /// remaining sources.
    ///
    /// A failed attempt is routed to `onError`, which can `.retry` the source (any partial
    /// bytes discarded first), `.skip` it (collect and continue — the default), or `.abort`
    /// the whole operation. The loop re-attempts as long as the resolver keeps asking.
    private func transfer(_ source: SizedSource) -> Bool {
        let entry = source.entry
        // `landingName` rather than `entry.name`: a rename the backend refused in place arrives here
        // as a one-source move that lands under a *different* name (`FileOperation.renamedTo`).
        let destination = operation.destinationDirectory.appending(operation.landingName(for: entry))
        // The tallies to roll back to before each attempt, so a failed-then-retried copy doesn't
        // double-count the bytes and files it wrote before failing.
        let before = tally.mark
        while true {
            tally.emit(current: entry.path, force: true)
            do {
                try attempt(source, to: destination)
                return true
            } catch is CancellationError {
                return false
            } catch {
                let failure = (error as? VFSError) ?? .io(path: entry.path, code: 0)
                tally.rollBack(to: before) // discard the failed attempt's partial progress
                switch resolveError(entry, failure) {
                case .retry:
                    continue
                case .skip:
                    failures.append(OperationItemFailure(path: entry.path, error: failure))
                    return true
                case .abort:
                    return false // unwind the whole op, reported canceled like a user cancel
                }
            }
        }
    }

    /// One attempt to transfer `entry`, resolving the destination conflict and moving the
    /// bytes. Records the item's disposition (`skipped`/`outcomes`) only on success; a throw
    /// leaves those untouched so a retry re-runs cleanly.
    private func attempt(_ source: SizedSource, to destination: VFSPath) throws {
        let entry = source.entry
        switch try resolveConflict(for: entry, at: destination) {
        case .skip:
            skipped.append(entry.path)
            tally.finishItem(bytes: source.bytes, files: source.files)
            outcomes.append(.init(source: entry.path, landedAt: nil, replacedExisting: false))
        case let .proceed(target):
            do {
                try perform(source, to: target)
            } catch is CancellationError {
                // The target was free, so whatever is there now is this job's, and undo may remove
                // it. Nothing is there after a lone file, whose half-written bytes the backend
                // removes, and then there is nothing to record. A move's source is still whole: it
                // is removed only after the last byte (`perform`).
                if (try? backend.stat(at: target)) != nil {
                    stoppedPartway = .init(
                        source: entry.path,
                        landedAt: target,
                        replacedExisting: false
                    )
                }
                throw CancellationError()
            }
            tally.finishItem(bytes: 0, files: 0) // both were tallied inside `perform`
            outcomes.append(.init(source: entry.path, landedAt: target, replacedExisting: false))
        case let .overwrite(temp, existing, final):
            try replace(entry, via: temp, removing: existing, landingAt: final)
            outcomes.append(.init(source: entry.path, landedAt: final, replacedExisting: true))
        }
    }

    /// Ask the caller's `onError` resolver how to handle a failed source. Without one, keep
    /// the engine's unattended default: `.skip` (collect the failure and move on).
    private func resolveError(_ entry: FileEntry, _ error: VFSError) -> ErrorResolution {
        guard let onError else { return .skip }
        return onError(OperationErrorContext(kind: operation.kind, path: entry.path, error: error))
    }

    /// The overwrite path: copy the source to a temporary sibling, remove the existing
    /// item, then swap the temporary into place — and, for a move, delete the source
    /// afterwards. The original is never removed until its replacement is fully written.
    private func replace(
        _ entry: FileEntry,
        via temp: VFSPath,
        removing existing: VFSPath,
        landingAt final: VFSPath
    ) throws {
        try copyManual(entry, to: temp)
        try backend.removeItem(at: existing)
        try backend.moveItem(at: temp, to: final)
        if operation.kind == .move { try backend.removeItem(at: entry.path) }
        tally.finishItem(bytes: 0, files: 0) // `copyManual` tallied both
    }

    /// Copy or move `entry` onto a `target` that is guaranteed free. Move takes the
    /// same-volume rename fast path and falls back to copy-then-delete across volumes.
    private func perform(_ source: SizedSource, to target: VFSPath) throws {
        let entry = source.entry
        if operation.kind == .move {
            do {
                try backend.moveItem(at: entry.path, to: target)
                tally.add(bytes: source.bytes, files: source.files)
                return
            } catch let VFSError.io(_, code) where code == EXDEV {
                // Cross-volume: fall through to copy the bytes, then remove the source.
            }
            try copyManual(entry, to: target)
            try backend.removeItem(at: entry.path)
            return
        }

        // Copy: try a copy-on-write clone of the whole item first (instant same-volume) — but only
        // *within one backend*, and only where that backend advertises cloning. A CoW clone is a
        // single-filesystem primitive, so it can never span backends: an upload (local → SFTP) would
        // otherwise route the clone to `LocalBackend`, which reads the SFTP destination's path string
        // as a *local* path — cloning to nowhere (ENOENT → a spurious "no longer exists") or, worse,
        // silently onto the local disk instead of the remote. Cross-backend copies and a backend
        // without `.clone` (SFTP) go straight to the chunked path (PLAN.md §M5 "no clone → chunked").
        if entry.kind != .symlink,
           entry.path.backend == target.backend,
           backend.capabilities(for: entry.path).contains(.clone),
           try backend.cloneItem(at: entry.path, to: target) {
            tally.add(bytes: source.bytes, files: source.files)
            return
        }
        try copyManual(entry, to: target)
    }

    // MARK: - Manual recursive copy (the cross-volume / no-clone fallback)

    private func copyManual(_ entry: FileEntry, to target: VFSPath) throws {
        if isCancelled() { throw CancellationError() }
        switch entry.kind {
        case .symlink:
            // Duplicate the link itself, never its target — preserved even when dangling.
            //
            // A `nil` target is **refused**, and the distinction from an *empty* one is the whole
            // rule: empty is a link somebody really made (`symlink("")` succeeds on macOS — measured,
            // it returns 0 and leaves a 0-byte dangling link), while `nil` means this listing could
            // not read the target at all. `sftp`'s `ls` never prints one, so before §M25 Slice 4
            // every remote link copied as `ln -s ""` — a broken link reported as a successful copy,
            // which is the quiet failure this milestone exists to prevent. Where the exec channel can
            // answer, `resolvingSymlinkTargets` has already filled it in; where it cannot, this says
            // so. The same distinction §M25 Slice 1 draws for a `nil` mode: absent is not empty.
            guard let destination = entry.symlinkDestination else {
                throw VFSError.unsupported(.symbolicLinkTargetUnreadable(name: entry.name))
            }
            try backend.createSymbolicLink(at: target, withDestination: destination)
            tally.add(bytes: entry.byteSize, files: 1)
        case .directory:
            try backend.createDirectory(at: target)
            // Resolved as a batch, because the cost of learning a target is the *connection*
            // rather than the row — twelve links in one exec measured 79 ms against 77 ms for one —
            // so asking per child would turn a directory of links into a directory of round trips.
            let children = backend.resolvingSymlinkTargets(
                in: (try? backend.listDirectory(at: entry.path)) ?? []
            )
            for child in children {
                try copyManual(child, to: target.appending(child.name))
            }
            // The listing already read the mode and the date, so carrying them costs nothing here
            // and saves a remote backend a round trip it would otherwise have to spend asking
            // (PLAN.md §M25 Slice 2).
            try? backend.copyMetadata(
                at: entry.path,
                to: target,
                sourceMetadata: RemoteSourceMetadata(entry)
            )
        case .file, .other:
            tally.startFile(entry)
            try backend.copyFile(
                at: entry.path,
                to: target,
                // The listing already read all of it, so the hint costs nothing: the size is what
                // lets a remote backend split the transfer (docs/HISTORY.md ▸ After M19), and the mode and date are
                // what make carrying them free in *both* directions (PLAN.md §M25 Slice 2) — an
                // upload's source is local, and a download's would otherwise cost a whole connection
                // to ask about. A backend with no use for either copies exactly as before.
                hint: CopySourceHint(entry),
                progress: { [self] delta in tally.wrote(delta, of: entry.path) },
                isCancelled: isCancelled
            )
            tally.finishFile()
        }
    }

    // MARK: - Report

    private func report(canceled: Bool) -> OperationReport {
        OperationReport(
            completedItems: tally.completedItems,
            completedBytes: tally.completedBytes,
            skipped: skipped,
            failures: failures,
            wasCancelled: canceled,
            outcomes: outcomes,
            stoppedPartway: stoppedPartway,
            metadataLoss: metadataLoss()
        )
    }

    /// Every account this job touches, and what it had already lost.
    ///
    /// The *distinct* backends of the sources and the destination — a relay has two and an ordinary
    /// copy one, and asking each once is what makes reading it cheap: the tally is a lock and a
    /// dictionary copy, never a round trip.
    private func metadataTallies() -> [VFSBackendID: RemoteMetadataTally] {
        var paths = operation.sources.map(\.path)
        paths.append(operation.destinationDirectory)
        var tallies: [VFSBackendID: RemoteMetadataTally] = [:]
        for path in paths where tallies[path.backend] == nil {
            tallies[path.backend] = backend.metadataTally(at: path)
        }
        return tallies
    }

    /// What **this run** could not carry, or `nil` when it carried everything — the good case, and
    /// the one every local copy takes for free.
    ///
    /// Each account's delta, added up. A backend that appeared only at the end (nothing does today,
    /// but a route that reached a third connection would) is measured against `.zero`, which counts
    /// its whole tally — the safe direction, since the alternative is dropping a loss on the floor.
    private func metadataLoss() -> RemoteMetadataLoss? {
        var total = RemoteMetadataTally.zero
        for (id, ending) in metadataTallies() {
            total = total.adding(ending.since(startingTallies[id] ?? .zero))
        }
        return total.loss
    }
}

// MARK: - Conflict resolution

/// The per-source conflict handling, split into an extension so the main `CopyRun` body stays
/// under SwiftLint's type-body-length limit (the same treatment the snapshot helpers got).
private extension CopyRun {
    enum Plan {
        case proceed(VFSPath)
        case overwrite(temp: VFSPath, existing: VFSPath, final: VFSPath)
        case skip
    }

    func resolveConflict(for entry: FileEntry, at destination: VFSPath) throws -> Plan {
        guard let existing = try? backend.stat(at: destination) else { return .proceed(destination) }
        switch policy {
        case .fail:
            throw VFSError.alreadyExists(destination)
        case .skip:
            return .skip
        case .overwrite:
            return overwritePlan(at: destination, name: entry.name)
        case .newerOnly:
            return newerOnlyPlan(source: entry, existing: existing, at: destination)
        case .keepBoth:
            return keepBothPlan(for: entry)
        case .ask:
            return try askPlan(for: entry, existing: existing, at: destination)
        }
    }

    /// Consult the operation's resolver for one conflict and translate its answer into a
    /// `Plan`. A missing resolver degrades to the safe `.fail` behavior; `.cancel` aborts
    /// the whole operation through the engine's normal cancellation path.
    func askPlan(for entry: FileEntry, existing: FileEntry, at destination: VFSPath) throws -> Plan {
        guard let resolveConflict else { throw VFSError.alreadyExists(destination) }
        let context = ConflictContext(kind: operation.kind, source: entry, existing: existing)
        switch resolveConflict(context) {
        case .overwrite:
            return overwritePlan(at: destination, name: entry.name)
        case .overwriteIfNewer:
            return newerOnlyPlan(source: entry, existing: existing, at: destination)
        case .skip:
            return .skip
        case .keepBoth:
            return keepBothPlan(for: entry)
        case .cancel:
            throw CancellationError()
        }
    }

    /// Replace only a strictly-older destination; an equal-or-newer one is kept (skipped).
    func newerOnlyPlan(source: FileEntry, existing: FileEntry, at destination: VFSPath) -> Plan {
        guard source.modificationDate > existing.modificationDate else { return .skip }
        return overwritePlan(at: destination, name: source.name)
    }

    func keepBothPlan(for entry: FileEntry) -> Plan {
        .proceed(operation.destinationDirectory.appending(firstAvailableName(basedOn: entry.name)))
    }

    /// The plan for replacing an existing `destination` in place: write the replacement to
    /// a temporary sibling first, then swap it in, so the original survives a failure or
    /// cancellation partway through (see `replace(_:via:removing:landingAt:bytes:)`).
    func overwritePlan(at destination: VFSPath, name: String) -> Plan {
        let temp = operation.destinationDirectory
            .appending(".dirnex-copy-\(UUID().uuidString)-\(name)")
        return .overwrite(temp: temp, existing: destination, final: destination)
    }

    /// Generate the first "<name> copy[.ext]" / "<name> copy N[.ext]" that doesn't yet
    /// exist in the destination — Finder's keep-both naming.
    func firstAvailableName(basedOn name: String) -> String {
        let ns = name as NSString
        let ext = ns.pathExtension
        let stem = ns.deletingPathExtension
        let suffix = ext.isEmpty ? "" : ".\(ext)"
        var counter = 1
        while true {
            let candidate = counter == 1 ? "\(stem) copy\(suffix)" : "\(stem) copy \(counter)\(suffix)"
            let path = operation.destinationDirectory.appending(candidate)
            if (try? backend.stat(at: path)) == nil { return candidate }
            counter += 1
        }
    }
}
