import AppKit
import DirnexCore

/// A folder on a server dropped into Finder (PLAN.md §M36 Slice 3, decision B): the third kind of
/// promise `+DragPromise` fulfils, beside a server's file and an archive member.
///
/// **This one does go through the queue bar**, where the other two do not. A file's promise runs
/// outside every progress surface because the receiving app is blocked on it; Finder, holding a
/// folder's promise, blocks on nothing and draws nothing (probe P1, `RemoteFolderPromise`), so the
/// queue job F5 and ⌥F5 already use is the surface: a bar while the tree comes down, and a Stop that
/// leaves nothing in Finder's folder. Nothing is asked first. Finder has named the destination, the
/// copy is what the user's drop asked for, and a confirmation would be a sheet on Dirnex's window
/// behind the app the drop went to, which decision A ruled out for a passphrase.
extension PanelViewController {
    /// Stage `entry`'s tree through the queue, move it to `url`, and answer Finder on every path.
    ///
    /// Finder is answered before the user is told anything, since an alert with no window to sit on
    /// runs modally and would hold the answer behind it.
    func fulfillFolderPromise(
        _ entry: FileEntry,
        writingTo url: URL,
        then completionHandler: @escaping @Sendable ((any Error)?) -> Void
    ) {
        guard let host else {
            // A pane with no window controller cannot be reached by a drag, and still owes an answer.
            completionHandler(CocoaError(.fileReadUnknown))
            return
        }
        host.materializeRemoteFiles([entry]) { [weak self] report in
            Task { [weak self] in
                // Off the main actor: onto another volume the move is a copy of the whole tree.
                let outcome = await Task.detached {
                    RemoteFolderPromise.settle(report, for: entry, at: url)
                }.value
                completionHandler(outcome.answer)
                guard let failure = outcome.failure, let self else { return }
                presentOperationFailure(
                    message: String(
                        localized: "Couldn’t copy “\(entry.name)” from the server",
                        comment: """
                        Alert title when a folder dragged from a server into Finder can't be brought \
                        down or put where Finder asked; %@ is the folder's name.
                        """
                    ),
                    detail: describe(failure)
                )
            }
        }
    }
}
