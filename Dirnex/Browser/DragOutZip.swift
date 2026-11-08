import DirnexCore
import Foundation

/// A folder dragged toward an app that is not Finder, made into the zip that app is handed
/// (2026-11-08, asked for by Oleg after Gmail refused a folder).
///
/// Gmail answers "Attachment failed" for a folder dropped from Chrome, Finder's included, and Teams
/// and the rest of Chromium take a dropped file the same way. So once the pointer is over such an app,
/// the drag's handoff offers `<folder>.zip` in the folder's place (`DragOutRoute.zipsForOtherApps`).
/// Finder is never offered the zip: it takes a folder on this disk by its own URL, and a server's
/// folder by the promise the drag began with, or after a crossing by the staged tree this leaves.
///
/// Both halves are machinery that already ships. The zip is ⌥F5's own `bsdtar` writer
/// (`ArchivePacker`), and a server's folder comes down through `MaterializeRunner`, F5's engine
/// pointed at the temp root, as ⌥F5 stages one. A folder of 11 MB and 551 files zipped in 0.3 s and
/// 200 MB of random bytes in 2.7 s, measured on this Mac, so an ordinary folder is ready inside the
/// handoff's hold.
struct DragOutZip: Sendable {
    /// The folder row.
    let row: FileEntry
    /// The temp root the zip, and a server folder's staged tree, each get a directory under.
    let root: URL
    /// What a server's folder is staged through: the pane's routing backend, which a staging needs
    /// because it reads from the server and writes here (`MaterializeRunner`).
    let backend: any VFSBackend
    /// ⌥F5's `bsdtar` packer, or a test's stand-in.
    let writer: any PlainPackWriting

    /// What zipping one folder left in the temp root, for the drag to hand over and later remove.
    struct Made: Sendable {
        /// The row it stands for.
        let source: VFSPath
        /// The zip, in a directory of its own, which is what another app is handed.
        let zip: URL
        /// A server folder's staged tree, which Finder is handed after a crossing. `nil` for a folder
        /// on this disk, which Finder takes by its own URL.
        let staged: URL?

        /// Remove the zip's directory.
        func removeZip() {
            RemoteDragArtifacts.remove(holderOf: zip)
        }

        /// Remove the staged tree's directory.
        func removeStaged() {
            guard let staged else { return }
            RemoteDragArtifacts.remove(holderOf: staged)
        }
    }

    /// Zip the folder into a directory of its own under `root`, staging it first when it is on a
    /// server. Blocks, and leaves nothing behind when it throws.
    ///
    /// A failure of the zip itself comes out as ``DragOutZipFailure``, so the pane can say it was the
    /// compression that failed rather than the download; a server's refusal stays the server's.
    func run(
        onPhase: @Sendable (RemoteDragPhaseBox.Phase) -> Void,
        onBytes: @escaping @Sendable (Int64) -> Void,
        isCancelled: @escaping @Sendable () -> Bool
    ) throws -> Made {
        var staged: URL?
        let folder: URL
        if row.path.backend == .local {
            folder = row.path.localURL
        } else {
            onPhase(.downloading)
            let tree = try stage(onBytes: onBytes, isCancelled: isCancelled)
            staged = tree
            folder = tree
        }
        do {
            onPhase(.compressing)
            let zip = try compress(folder, isCancelled: isCancelled)
            return Made(source: row.path, zip: zip, staged: staged)
        } catch {
            if let staged { RemoteDragArtifacts.remove(holderOf: staged) }
            throw error
        }
    }

    /// Bring a server's folder down whole, through the queue's own runner without the queue.
    ///
    /// The handoff's transfer is something the pointer did, not a job the user asked for, so it is not
    /// queued (`RemoteDragHandoffController`); the runner is the same one ⌥F5 stages through.
    private func stage(
        onBytes: @escaping @Sendable (Int64) -> Void,
        isCancelled: @escaping @Sendable () -> Bool
    ) throws -> URL {
        let report = MaterializeRunner.run(
            FileOperation(
                kind: .materialize,
                sources: [row],
                destinationDirectory: .local(root.path)
            ),
            using: backend,
            onProgress: { onBytes($0.completedBytes) },
            isCancelled: isCancelled
        )
        if report.wasCancelled { throw CancellationError() }
        if let failure = report.failures.first { throw failure.error }
        guard let tree = report.materialized?.first(
            where: { $0.isDirectory && $0.source == row.path }
        )
        else { throw CocoaError(.fileReadUnknown) }
        return URL(fileURLWithPath: tree.localPath, isDirectory: true)
    }

    /// Write `folder` into `<name>.zip` in a fresh directory under `root`, with the folder itself as
    /// the zip's one top-level entry, as Finder's Compress and ⌥F5 both lay one out.
    private func compress(_ folder: URL, isCancelled: @escaping @Sendable () -> Bool) throws -> URL {
        let holder = root.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let zip = holder.appendingPathComponent(DragOutRoute.zipName(forFolderNamed: row.name))
        do {
            try FileManager.default.createDirectory(at: holder, withIntermediateDirectories: true)
            try writer.pack(
                PlainPackRequest(
                    sources: [PackSource(
                        directory: folder.deletingLastPathComponent().path,
                        name: folder.lastPathComponent
                    )],
                    archiveOnDiskPath: zip.path,
                    format: .zip,
                    level: .normal
                ),
                onProgress: { _ in },
                isCancelled: isCancelled
            )
            return zip
        } catch is CancellationError {
            try? FileManager.default.removeItem(at: holder)
            throw CancellationError()
        } catch {
            try? FileManager.default.removeItem(at: holder)
            throw DragOutZipFailure(folderName: row.name, underlying: error)
        }
    }
}

extension [DragOutZip.Made] {
    /// Remove what the drop did not use, keeping what an app may still be reading.
    ///
    /// Finder copies a folder after the drop and an upload reads its zip after it, so what was taken
    /// stays until the temp root is cleared at the next launch, as a downloaded copy does. `surface`
    /// is where the pointer let go, or `nil` when nothing took the drop.
    func sweep(droppedOn surface: RemoteDragHandoff.Surface?) {
        for made in self {
            switch surface {
            case .finder?: made.removeZip()
            case .otherApp?: made.removeStaged()
            case .neutral?, nil:
                made.removeZip()
                made.removeStaged()
            }
        }
    }
}

/// A folder that could not be made into a zip for another app, as opposed to one that could not be
/// brought down from its server.
struct DragOutZipFailure: Error {
    let folderName: String
    let underlying: any Error
}

/// Removing what a drag left in the temp root.
enum RemoteDragArtifacts {
    /// Remove the directory holding `url`, when it is one this app made under the temp root.
    ///
    /// The guard `RemoteFileCache.sweepStagedTrees` keeps: anything a drag made is in a directory of
    /// its own under the temp root, and nothing else may be removed through here.
    static func remove(holderOf url: URL) {
        let root = RemoteFileCache.temporaryRoot.standardizedFileURL.path
        let holder = url.standardizedFileURL.deletingLastPathComponent()
        guard holder.path.hasPrefix(root + "/") else { return }
        try? FileManager.default.removeItem(at: holder)
    }
}
