import DirnexCore
import Foundation

/// A folder dragged into an app with Shift held, made into the zip that app is handed (2026-11-08,
/// asked for by Oleg after Gmail refused a folder; behind Shift since 2026-11-09, after VLC was handed
/// a zip of a whole season it would have played as a folder).
///
/// Gmail answers "Attachment failed" for a folder dropped from Chrome, Finder's included, and Teams
/// and the rest of Chromium take a dropped file the same way, while VLC and Finder take a folder. Nothing
/// tells a drag which an app wants, so the folder goes as itself unless the pointer enters the app with
/// Shift held, when the handoff offers `<folder>.zip` in its place (`DragOutRoute.zipsWithShift`).
///
/// The zip is ⌥F5's own `bsdtar` writer (`ArchivePacker`). A server's folder is zipped from the tree
/// the drag's transfer staged (`RemoteDragTransfer`), F5's engine pointed at the temp root, so the
/// tree that serves the folder's own form serves its zip too. A folder of 11 MB and 551 files zipped
/// in 0.3 s and 200 MB of random bytes in 2.7 s, measured on this Mac, so an ordinary folder is ready
/// inside the handoff's hold.
struct DragOutZip: Sendable {
    /// The folder row.
    let row: FileEntry
    /// The folder's bytes on this disk: the row's own folder, or a server folder's staged tree.
    let folder: URL
    /// The temp root the zip gets a directory of its own under.
    let root: URL
    /// ⌥F5's `bsdtar` packer, or a test's stand-in.
    let writer: any PlainPackWriting

    /// Write `folder` into `<name>.zip` in a fresh directory under `root`, with the folder itself as
    /// the zip's one top-level entry, as Finder's Compress and ⌥F5 both lay one out. Blocks, and leaves
    /// nothing behind when it throws.
    ///
    /// A failure of the zip itself comes out as ``DragOutZipFailure``, so the pane can say it was the
    /// compression that failed rather than the download.
    func run(isCancelled: @escaping @Sendable () -> Bool) throws -> URL {
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

/// Every folder of one drag zipped in turn, on a thread of their own, once the transfer has landed.
///
/// All or none, as the board hands over all of its rows or none of them: a set that fails or is
/// stopped removes every zip it made.
struct DragOutCompression: Sendable {
    let zips: [DragOutZip]
    let cancellation: CancellationFlag

    /// Run every folder, in order. Blocks.
    func run() -> DragOutCompressionOutcome.Settled {
        var made: [VFSPath: URL] = [:]
        do {
            for zip in zips {
                if cancellation.isCancelled { throw CancellationError() }
                made[zip.row.path] = try zip.run(isCancelled: { cancellation.isCancelled })
            }
            return .init(zips: made, error: nil)
        } catch {
            for url in made.values {
                RemoteDragArtifacts.remove(holderOf: url)
            }
            return .init(zips: [:], error: error)
        }
    }
}

/// What a drag's zips ended with, handed from their thread to the main actor, for the reason
/// `RemoteDragTransferOutcome` is a box.
final class DragOutCompressionOutcome: @unchecked Sendable {
    struct Settled {
        /// Each folder's zip, in a directory of its own under the temp root.
        let zips: [VFSPath: URL]
        let error: (any Error)?
    }

    private let lock = NSLock()
    private var value: Settled?

    var settled: Settled? {
        lock.withLock { value }
    }

    func settle(_ settled: Settled) {
        lock.withLock { value = settled }
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

    /// Remove what the drop did not take. `taken` is what the board offered a folder as when an app
    /// took the drop, or `nil` when nothing did.
    ///
    /// Finder copies a folder after the drop and an upload reads its zip after it, so what was taken
    /// stays until the temp root is cleared at the next launch, as a downloaded copy does.
    static func sweep(
        zips: [URL],
        stagedTrees: [URL],
        taken: RemoteDragHandoff.Form?
    ) {
        if taken != .zips {
            for zip in zips {
                remove(holderOf: zip)
            }
        }
        if taken != .folders {
            for tree in stagedTrees {
                remove(holderOf: tree)
            }
        }
    }
}
