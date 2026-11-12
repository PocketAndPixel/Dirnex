import DirnexCore
import Foundation

/// The bytes behind one drag's handoff, brought down, extracted or staged on a thread of their own
/// (`RemoteDragHandoffController`).
///
/// A member is extracted rather than downloaded (`DragOutExtraction`), with what the main actor knew
/// about its archive gathered up front, and a server's folder is staged whole, as ⌥F5 stages one. The
/// two report no bytes as they go, so the count moves a whole row at a time. A folder's zip is not
/// made here: it is wanted only for an app entered with Shift held, and made afterwards from what this left
/// (`DragOutCompression`). A set that fails or is stopped removes every tree it staged, since the
/// board hands over all of its rows or none of them.
struct RemoteDragTransfer: Sendable {
    let rows: [FileEntry]
    let extractions: [VFSPath: DragOutExtraction]
    let backend: any VFSBackend
    /// Written as the transfer goes and read when the status is drawn.
    let moved: ByteCounter
    let phase: RemoteDragPhaseBox
    let cancellation: CancellationFlag

    /// Run every row, in order. Blocks.
    func run() -> RemoteDragTransferOutcome.Settled {
        var landed: [MaterializedFile] = []
        var extracted: [VFSPath: URL] = [:]
        var staged: [VFSPath: URL] = [:]
        var done: Int64 = 0
        do {
            for row in rows {
                let before = done
                if let extraction = extractions[row.path] {
                    // An extraction cannot be stopped once it starts, so a drag already called off
                    // starts none. A download is left to see the flag itself, as it always has:
                    // checked here too, a stop that beat the first row would never reach the server,
                    // which is the stop `RemoteDragHandoffEndingTests` watches for.
                    if cancellation.isCancelled { throw CancellationError() }
                    phase.value = .extracting
                    extracted[row.path] = try extraction.run()
                } else if row.kind == .directory {
                    if cancellation.isCancelled { throw CancellationError() }
                    phase.value = .downloading
                    staged[row.path] = try stage(row, onBytes: { moved.value = before + $0 })
                } else {
                    phase.value = .downloading
                    try landed.append(MaterializeRunner.materialize(
                        row,
                        intoDirectory: RemoteFileCache.temporaryRoot.path,
                        using: backend,
                        onBytes: { moved.value = before + $0 },
                        isCancelled: { cancellation.isCancelled }
                    ))
                }
                done += max(row.byteSize, 0)
                moved.value = done
            }
            return .init(landed: landed, extracted: extracted, staged: staged, error: nil)
        } catch {
            for tree in staged.values {
                RemoteDragArtifacts.remove(holderOf: tree)
            }
            return .init(landed: landed, extracted: extracted, staged: [:], error: error)
        }
    }

    /// Bring a server's folder down whole, through the queue's own runner without the queue.
    ///
    /// The handoff's transfer is something the pointer did, not a job the user asked for, so it is not
    /// queued (`RemoteDragHandoffController`); the runner is the same one ⌥F5 stages through. The tree
    /// lands in a directory of its own under the temp root, which is what lets the drag's end remove
    /// it (`RemoteDragArtifacts`).
    private func stage(_ row: FileEntry, onBytes: @escaping @Sendable (Int64) -> Void) throws -> URL {
        let report = MaterializeRunner.run(
            FileOperation(
                kind: .materialize,
                sources: [row],
                destinationDirectory: .local(RemoteFileCache.temporaryRoot.path)
            ),
            using: backend,
            onProgress: { onBytes($0.completedBytes) },
            isCancelled: { cancellation.isCancelled }
        )
        if report.wasCancelled { throw CancellationError() }
        if let failure = report.failures.first { throw failure.error }
        guard let tree = report.materialized?.first(
            where: { $0.isDirectory && $0.source == row.path }
        )
        else { throw CocoaError(.fileReadUnknown) }
        return URL(fileURLWithPath: tree.localPath, isDirectory: true)
    }

    /// What the line under the row says before the transfer has said anything itself.
    static func phase(
        startingWith row: FileEntry,
        routes: [VFSPath: DragOutRoute]
    ) -> RemoteDragPhaseBox.Phase {
        routes[row.path] == .extract ? .extracting : .downloading
    }
}
