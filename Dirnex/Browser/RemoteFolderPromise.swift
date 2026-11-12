import DirnexCore
import Foundation

/// Finder's promise for a folder on a server, settled once the queue has staged the tree (PLAN.md
/// §M36 Slice 3, decision B).
///
/// M23 left a server's folder inside Dirnex because a promise was one file, and a recursive fetch
/// behind somebody else's drop had no progress surface and no way to stop it. Both answers already
/// existed: `MaterializeRunner` has staged a whole folder as a queue job with a bar and Stop since
/// 2026-08-30, which is F5's own engine pointed at the temp root. What was missing was how Finder
/// treats a promised folder, which probe P1 measured on 2026-11-08 with a throwaway drag source:
///
/// - Finder takes a promise whose type is `public.folder`, and asks for it at the drop folder's own
///   path. **Nothing is there when it asks**, and when the name is taken it asks for `Name 2` itself.
/// - The drag ends as soon as Finder has asked, reporting a copy however the promise is answered.
/// - **Finder draws nothing while it waits** and stays responsive: AppleEvents to it took the usual
///   ~140 ms, and it took a folder answered 100 s after the drop.
/// - **An error answer shows nothing and leaves nothing.** So the user hears about a failure from
///   Dirnex or from nobody.
///
/// So the tree is staged where every server fetch lands and moved to Finder's path only when the
/// whole of it is here: Stop or a failure leaves nothing in Finder's folder. The queue's bar is the
/// only progress there is, which is the trade decision B took.
enum RemoteFolderPromise {
    /// What the promise ends with.
    struct Outcome: Sendable {
        /// What Finder is told: `nil` once the folder is at its path, an error otherwise.
        let answer: (any Error)?
        /// What the user is told, since Finder says nothing. `nil` when the folder arrived, and when
        /// the user stopped it, which is their own answer and already on screen in the queue bar.
        let failure: (any Error)?
    }

    /// Settle `report`, the staging job's, for `entry`, putting the tree at `url` if it all came down.
    ///
    /// Blocks: a drop onto another volume makes the move a copy of the whole tree, so the caller runs
    /// this off the main actor. Whatever happens, nothing of the staged tree is left in the temp root.
    static func settle(_ report: OperationReport, for entry: FileEntry, at url: URL) -> Outcome {
        let staged = report.materialized?
            .first { $0.source == entry.path && $0.isDirectory }
            .map { URL(fileURLWithPath: $0.localPath, isDirectory: true) }
        guard !report.wasCancelled else {
            sweep(staged)
            return Outcome(answer: CancellationError(), failure: nil)
        }
        guard let staged, report.failures.isEmpty else {
            sweep(staged)
            let error: any Error = report.failures.first?.error ?? CocoaError(.fileReadUnknown)
            return Outcome(answer: error, failure: error)
        }
        if let error = place(staged, at: url) {
            sweep(staged)
            return Outcome(answer: error, failure: error)
        }
        sweep(staged)
        return Outcome(answer: nil, failure: nil)
    }

    /// Move the staged tree to the path Finder asked for.
    ///
    /// **Something already there is not ours.** P1 found the path empty every time Finder asked, so
    /// whatever is there now arrived while the folder was coming down, from the user or another
    /// drop, and is left alone. (A *file's* promise replaces what it finds, because that is a
    /// placeholder an earlier attempt left; a folder has no such history, and replacing one would
    /// delete a tree nobody named.)
    ///
    /// A move onto another volume is a copy, and a copy that fails partway is removed, so a failure
    /// leaves nothing under Finder's name either.
    static func place(_ staged: URL, at url: URL) -> (any Error)? {
        let files = FileManager.default
        guard !files.fileExists(atPath: url.path) else {
            return CocoaError(.fileWriteFileExists, userInfo: [NSFilePathErrorKey: url.path])
        }
        do {
            try files.moveItem(at: staged, to: url)
            return nil
        } catch {
            try? files.removeItem(at: url)
            return error
        }
    }

    /// Remove the directory `MaterializeRunner` staged the tree in, holder and all, whether the tree
    /// is still in it or has been moved out (`RemoteFileCache.sweepStagedTrees` needs it still there,
    /// and after a move it is not).
    private static func sweep(_ staged: URL?) {
        guard let staged else { return }
        RemoteDragArtifacts.remove(holderOf: staged)
    }
}
