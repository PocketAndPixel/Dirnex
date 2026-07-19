import Foundation

/// Executes a `FileOperation` (copy or move) against a backend, reporting progress and
/// honouring cancellation — TC's queued, non-blocking file operations (PLAN.md §M2).
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
    ///   `.abort` unwinds the whole operation as cancelled. A missing resolver behaves as
    ///   `.skip`, so an unattended run still finishes and summarizes its failures.
    /// - `onProgress` is called periodically (throttled by byte volume and at each item
    ///   boundary) — never per chunk, so a 50 GB copy doesn't flood the caller.
    /// - `isCancelled` is polled between chunks and items; cancelling leaves a report with
    ///   `wasCancelled == true` and cleans up any half-written file (a partially copied
    ///   directory tree is left in place for the user to remove).
    public static func run(
        _ operation: FileOperation,
        using backend: any VFSBackend,
        conflictPolicy: ConflictPolicy = .fail,
        resolveConflict: (@Sendable (ConflictContext) -> ConflictResolution)? = nil,
        onError: (@Sendable (OperationErrorContext) -> ErrorResolution)? = nil,
        onProgress: @escaping @Sendable (OperationProgress) -> Void = { _ in },
        isCancelled: @escaping @Sendable () -> Bool = { false }
    ) -> OperationReport {
        CopyRun(
            operation: operation,
            backend: backend,
            policy: conflictPolicy,
            resolveConflict: resolveConflict,
            onError: onError,
            onProgress: onProgress,
            isCancelled: isCancelled
        ).execute()
    }
}

/// One execution of a `FileOperation`. A short-lived class (never shared across tasks)
/// so the recursive copy and its helpers can share a running byte/item tally without
/// threading `inout` accumulators through every call.
private final class CopyRun {
    private let operation: FileOperation
    private let backend: any VFSBackend
    private let policy: ConflictPolicy
    private let resolveConflict: (@Sendable (ConflictContext) -> ConflictResolution)?
    private let onError: (@Sendable (OperationErrorContext) -> ErrorResolution)?
    private let onProgress: @Sendable (OperationProgress) -> Void
    private let isCancelled: @Sendable () -> Bool

    /// Emit a progress update at most this often by byte volume, so a large file reports
    /// smoothly without a main-actor hop per 1 MiB chunk.
    private static let emitThreshold: Int64 = 8 << 20

    private var totalBytes: Int64 = 0
    private var completedBytes: Int64 = 0
    private var completedItems = 0
    private var lastEmitted: Int64 = -1
    private var skipped: [VFSPath] = []
    private var failures: [OperationItemFailure] = []
    private var outcomes: [OperationItemOutcome] = []

    init(
        operation: FileOperation,
        backend: any VFSBackend,
        policy: ConflictPolicy,
        resolveConflict: (@Sendable (ConflictContext) -> ConflictResolution)?,
        onError: (@Sendable (OperationErrorContext) -> ErrorResolution)?,
        onProgress: @escaping @Sendable (OperationProgress) -> Void,
        isCancelled: @escaping @Sendable () -> Bool
    ) {
        self.operation = operation
        self.backend = backend
        self.policy = policy
        self.resolveConflict = resolveConflict
        self.onError = onError
        self.onProgress = onProgress
        self.isCancelled = isCancelled
    }

    func execute() -> OperationReport {
        let sized = preScan()
        totalBytes = sized.reduce(0) { $0 + $1.bytes }
        emit(current: nil, force: true)

        for item in sized {
            if isCancelled() { return report(cancelled: true) }
            if !transfer(item.entry, bytes: item.bytes) {
                return report(cancelled: true) // cancelled mid-item
            }
        }
        return report(cancelled: false)
    }

    // MARK: - Pre-scan

    /// Measure each source's byte weight up front for the progress denominator, reusing
    /// the directory sizer for subtrees. A source we can't size counts as 0 rather than
    /// aborting the whole operation.
    private func preScan() -> [(entry: FileEntry, bytes: Int64)] {
        operation.sources.map { entry in
            let bytes: Int64
            if entry.kind == .directory {
                bytes = (
                    try? DirectorySizer.size(
                        of: entry.path,
                        using: backend,
                        isCancelled: isCancelled
                    )
                ) ?? 0
            } else {
                bytes = entry.byteSize
            }
            return (entry, bytes)
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
    private func transfer(_ entry: FileEntry, bytes: Int64) -> Bool {
        let destination = operation.destinationDirectory.appending(entry.name)
        // The byte tally to roll back to before each attempt, so a failed-then-retried copy
        // doesn't double-count the bytes it wrote before failing.
        let bytesBefore = completedBytes
        while true {
            emit(current: entry.path, force: true)
            do {
                try attempt(entry, to: destination, bytes: bytes)
                return true
            } catch is CancellationError {
                return false
            } catch {
                let failure = (error as? VFSError) ?? .io(path: entry.path, code: 0)
                completedBytes = bytesBefore // discard the failed attempt's partial progress
                switch resolveError(entry, failure) {
                case .retry:
                    continue
                case .skip:
                    failures.append(OperationItemFailure(path: entry.path, error: failure))
                    return true
                case .abort:
                    return false // unwind the whole op, reported cancelled like a user cancel
                }
            }
        }
    }

    /// One attempt to transfer `entry`, resolving the destination conflict and moving the
    /// bytes. Records the item's disposition (`skipped`/`outcomes`) only on success; a throw
    /// leaves those untouched so a retry re-runs cleanly.
    private func attempt(_ entry: FileEntry, to destination: VFSPath, bytes: Int64) throws {
        switch try resolveConflict(for: entry, at: destination) {
        case .skip:
            skipped.append(entry.path)
            account(bytes: bytes)
            outcomes.append(.init(source: entry.path, landedAt: nil, replacedExisting: false))
        case let .proceed(target):
            try perform(entry, to: target, bytes: bytes)
            account(bytes: 0) // bytes were tallied inside `perform`
            outcomes.append(.init(source: entry.path, landedAt: target, replacedExisting: false))
        case let .overwrite(temp, existing, final):
            try replace(entry, via: temp, removing: existing, landingAt: final, bytes: bytes)
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
        landingAt final: VFSPath,
        bytes: Int64
    ) throws {
        try copyManual(entry, to: temp)
        try backend.removeItem(at: existing)
        try backend.moveItem(at: temp, to: final)
        if operation.kind == .move { try backend.removeItem(at: entry.path) }
        account(bytes: 0)
    }

    /// Copy or move `entry` onto a `target` that is guaranteed free. Move takes the
    /// same-volume rename fast path and falls back to copy-then-delete across volumes.
    private func perform(_ entry: FileEntry, to target: VFSPath, bytes: Int64) throws {
        if operation.kind == .move {
            do {
                try backend.moveItem(at: entry.path, to: target)
                completedBytes += bytes
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
            completedBytes += bytes
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
            try backend.createSymbolicLink(
                at: target,
                withDestination: entry.symlinkDestination ?? ""
            )
            completedBytes += entry.byteSize
        case .directory:
            try backend.createDirectory(at: target)
            let children = (try? backend.listDirectory(at: entry.path)) ?? []
            for child in children {
                try copyManual(child, to: target.appending(child.name))
            }
            try? backend.copyMetadata(at: entry.path, to: target)
        case .file, .other:
            try backend.copyFile(
                at: entry.path,
                to: target,
                progress: { [self] delta in
                    completedBytes += delta
                    emit(current: entry.path, force: false)
                },
                isCancelled: isCancelled
            )
        }
    }

    // MARK: - Progress accounting

    private func account(bytes: Int64) {
        completedBytes += bytes
        completedItems += 1
        emit(current: nil, force: true)
    }

    private func emit(current: VFSPath?, force: Bool) {
        guard force || completedBytes - lastEmitted >= Self.emitThreshold else { return }
        lastEmitted = completedBytes
        onProgress(OperationProgress(
            totalBytes: totalBytes,
            completedBytes: completedBytes,
            totalItems: operation.sources.count,
            completedItems: completedItems,
            currentItem: current
        ))
    }

    private func report(cancelled: Bool) -> OperationReport {
        OperationReport(
            completedItems: completedItems,
            completedBytes: completedBytes,
            skipped: skipped,
            failures: failures,
            wasCancelled: cancelled,
            outcomes: outcomes
        )
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
    /// `Plan`. A missing resolver degrades to the safe `.fail` behaviour; `.cancel` aborts
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
