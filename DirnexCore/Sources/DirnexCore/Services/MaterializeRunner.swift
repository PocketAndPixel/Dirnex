import Foundation

/// One remote object's bytes, brought down to a real path on this disk (PLAN.md §M24 Slice 2).
public struct MaterializedFile: Sendable, Equatable {
    /// The row this copy stands for, on whatever backend it lives.
    public let source: VFSPath
    /// Where the copy landed — an absolute local path, in its own directory under the job's root.
    public let localPath: String
    /// What the object looked like when the bytes were taken.
    ///
    /// Carried home with the copy rather than re-derived later, because it is what a save-back
    /// compares against before it overwrites (`RemoteFileRevision`) and the listing it came from may
    /// have been refreshed by the time anybody asks.
    public let revision: RemoteFileRevision

    public init(source: VFSPath, localPath: String, revision: RemoteFileRevision) {
        self.source = source
        self.localPath = localPath
        self.revision = revision
    }
}

/// Executes a `.materialize` operation: pull a set of remote rows down so the gesture behind them
/// can hand real paths to something that only understands real paths (PLAN.md §M24 Slice 2).
///
/// `PackRunner`'s shape exactly — a synchronous entry point returning an `OperationReport`, progress
/// through a callback, cancellation polled between files, and the caller deciding where it runs.
/// Being a queue job rather than a loop somewhere in the app is the whole point of the slice, and it
/// is not for tidiness: a marked set is the shape every M24 gesture has, and an N-file transfer
/// needs a determinate bar, a Stop, per-item failures and the queue's pause — all of which exist
/// already and none of which is worth a second implementation.
///
/// **It fills nothing.** The runner produces ``MaterializedFile`` values and the *caller* records
/// them, because the store is `RemoteFileCache` — a window-scoped `@MainActor` object `DirnexCore`
/// cannot see, and one whose whole correctness argument is that there is a single way in. A runner
/// that wrote into a cache of its own would be a second store with a second staleness rule.
///
/// **Nothing here is undoable, and that is a property rather than an omission.** The report carries
/// no ``OperationReport/outcomes``, so `UndoJournal` has nothing to build a record from — which is
/// right: reversing a materialize would mean putting a temp copy back, and there is no user-visible
/// change to reverse in the first place.
public enum MaterializeRunner {
    /// Bring every source down, reporting as it goes.
    ///
    /// - `operation.kind` must be `.materialize` and `operation.destinationDirectory` must be a
    ///   local directory — the temp root each copy gets its own subdirectory under. A mismatch
    ///   returns an empty report rather than trapping, the same way every other runner degrades a
    ///   dispatch bug to "nothing happened".
    /// - A file that fails is recorded and the run **continues**. Which is right for a checksum over
    ///   forty objects and wrong for ⌥F3, where one missing side makes the answer meaningless — so
    ///   the decision belongs to the gesture reading ``OperationReport/failures``, not to the loop.
    /// - `isCancelled` is polled between files and inside each transfer. A cancelled run leaves
    ///   nothing half-written: the file being transferred takes its whole directory with it, because
    ///   a truncated document renders as damage rather than as an error (the rule
    ///   `RemoteFileCache.fetch` already follows, and the opposite of what F5 wants from the same
    ///   bytes).
    public static func run(
        _ operation: FileOperation,
        using backend: any VFSBackend,
        onProgress: @escaping @Sendable (OperationProgress) -> Void = { _ in },
        isCancelled: @escaping @Sendable () -> Bool = { false },
        directoryName: @escaping @Sendable () -> String = { UUID().uuidString }
    ) -> OperationReport {
        guard case .materialize = operation.kind,
              operation.destinationDirectory.backend == .local else { return .empty }

        let root = operation.destinationDirectory.path
        // The listing already measured every source, which is what makes the bar determinate from
        // the first update instead of growing as files are discovered — and what let
        // `MaterializationPlan` state the same total to the user before any of this started.
        let totalBytes = operation.sources.reduce(into: Int64(0)) { $0 += max(0, $1.byteSize) }
        var landed: [MaterializedFile] = []
        var failures: [OperationItemFailure] = []
        var completedBytes: Int64 = 0

        for entry in operation.sources {
            if isCancelled() { return report(landed, failures, completedBytes, cancelled: true) }
            // Everything the progress closure needs, as constants: it is `@Sendable`, so it may
            // read what this iteration decided and must not accumulate anything of its own.
            let before = completedBytes
            let done = landed.count + failures.count
            let step: @Sendable (Int64) -> Void = { moved in
                onProgress(
                    OperationProgress(
                        totalBytes: totalBytes,
                        completedBytes: before + moved,
                        totalItems: operation.sources.count,
                        completedItems: done,
                        currentItem: entry.path
                    )
                )
            }
            step(0)
            do {
                let file = try materialize(
                    entry,
                    intoDirectory: root,
                    using: backend,
                    named: directoryName(),
                    onBytes: step,
                    isCancelled: isCancelled
                )
                landed.append(file)
                // From the object's own size, never from what the transfer reported: a backend that
                // reports nothing at all (an `sftp` upload has no meter a spawned process can read)
                // would otherwise leave the bar short of the total it started with.
                completedBytes = before + max(0, entry.byteSize)
            } catch is CancellationError {
                return report(landed, failures, before, cancelled: true)
            } catch {
                completedBytes = before
                // `CopyEngine`'s own spelling: a backend error is already a `VFSError`, and
                // anything else can only have come from the file manager, which the path names
                // better than a code nobody can look up would.
                let failure = (error as? VFSError) ?? .io(path: entry.path, code: 0)
                failures.append(OperationItemFailure(path: entry.path, error: failure))
            }
        }
        return report(landed, failures, completedBytes, cancelled: false)
    }

    /// Pull one object down into its own fresh directory under `directory`, keeping its real name.
    ///
    /// **One definition of "fetch this row", shared with `RemoteFileCache.fetch`.** The cache's
    /// single-file path — the preview following the cursor, ⏎, F4 — and this loop are the same
    /// transfer, and the layout is not incidental to either: a directory per file is what keeps two
    /// objects called `report.pdf` from different prefixes apart, and keeping the **real name**
    /// inside it is what an editor shows and what the write-back watcher watches (docs/NOTES.md ▸
    /// AppKit, on watching the directory rather than the file).
    ///
    /// Throws whatever the backend threw, having removed the directory first, so a failed or
    /// cancelled attempt leaves nothing for a later reader to mistake for a whole file.
    public static func materialize(
        _ entry: FileEntry,
        intoDirectory directory: String,
        using backend: any VFSBackend,
        named directoryName: String = UUID().uuidString,
        onBytes: @escaping @Sendable (Int64) -> Void = { _ in },
        isCancelled: @escaping @Sendable () -> Bool = { false }
    ) throws -> MaterializedFile {
        let holder = URL(fileURLWithPath: directory, isDirectory: true)
            .appendingPathComponent(directoryName, isDirectory: true)
        let destination = holder.appendingPathComponent(entry.name)
        do {
            try FileManager.default.createDirectory(at: holder, withIntermediateDirectories: true)
            var moved: Int64 = 0
            try backend.copyFile(
                at: entry.path,
                to: .local(destination.path),
                expectedSize: entry.byteSize,
                progress: { chunk in
                    moved += chunk
                    onBytes(moved)
                },
                isCancelled: isCancelled
            )
        } catch {
            try? FileManager.default.removeItem(at: holder)
            throw error
        }
        return MaterializedFile(
            source: entry.path,
            localPath: destination.path,
            revision: RemoteFileRevision(entry)
        )
    }

    private static func report(
        _ landed: [MaterializedFile],
        _ failures: [OperationItemFailure],
        _ completedBytes: Int64,
        cancelled: Bool
    ) -> OperationReport {
        OperationReport(
            completedItems: landed.count,
            completedBytes: completedBytes,
            skipped: [],
            failures: failures,
            wasCancelled: cancelled,
            materialized: landed
        )
    }
}
