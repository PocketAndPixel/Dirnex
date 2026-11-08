import DirnexCore
import Foundation

/// The bytes behind one drag's handoff, brought down, extracted or zipped on a thread of their own
/// (`RemoteDragHandoffController`).
///
/// A member is extracted rather than downloaded (`DragOutExtraction`), with what the main actor knew
/// about its archive gathered up front, and a folder is zipped (`DragOutZip`). Neither reports bytes
/// as it goes, so the count moves a whole row at a time. A set that fails or is stopped removes every
/// zip it made, since the board hands over all of its rows or none of them.
struct RemoteDragTransfer: Sendable {
    let rows: [FileEntry]
    let extractions: [VFSPath: DragOutExtraction]
    let zips: [VFSPath: DragOutZip]
    let backend: any VFSBackend
    /// Written as the transfer goes and read when the status is drawn.
    let moved: ByteCounter
    let phase: RemoteDragPhaseBox
    let cancellation: CancellationFlag

    /// Run every row, in order. Blocks.
    func run() -> RemoteDragTransferOutcome.Settled {
        var landed: [MaterializedFile] = []
        var extracted: [VFSPath: URL] = [:]
        var zipped: [DragOutZip.Made] = []
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
                } else if let zip = zips[row.path] {
                    if cancellation.isCancelled { throw CancellationError() }
                    try zipped.append(zip.run(
                        onPhase: { phase.value = $0 },
                        onBytes: { moved.value = before + $0 },
                        isCancelled: { cancellation.isCancelled }
                    ))
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
            return .init(landed: landed, extracted: extracted, zipped: zipped, error: nil)
        } catch {
            zipped.sweep(droppedOn: nil)
            return .init(landed: landed, extracted: extracted, zipped: [], error: error)
        }
    }

    /// What the line under the row says before the transfer has said anything itself.
    static func phase(
        startingWith row: FileEntry,
        routes: [VFSPath: DragOutRoute]
    ) -> RemoteDragPhaseBox.Phase {
        switch routes[row.path] {
        case .extract?: .extracting
        case .folderURL?: .compressing
        default: .downloading
        }
    }
}
