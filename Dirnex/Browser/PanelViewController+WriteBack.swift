import DirnexCore
import Foundation

/// Where a copy of a row that is not on this disk goes back to when something edits it, and the
/// watch that notices (PLAN.md §M4, §M21 Slice 10, §M24 Slice 5).
///
/// Three gestures hand a temp copy of such a row to something that will write to it — F4 inside an
/// archive, F4 on a server, and a user script over the marked set — and all three owe the user the
/// same thing afterwards: notice the save and offer to carry it back, rather than leave it in a
/// temp directory nobody will look in again. `EditedFileRegistry` does the noticing; this is the one
/// place that decides *whether* a row has anywhere to go back to, and starts the watch.
///
/// **It is one function because it was two and was about to be three.** Each F4 site built its own
/// `EditedFile` behind its own gate, which is the shape this project keeps paying for — one rule,
/// several spellings, and the compiler checking none of them (docs/NOTES.md ▸ Design lessons). A
/// script would have been the third, and the first one written by somebody who had not read the
/// other two.
///
/// **`nil` means "not watched", never "not writable".** A member of a *nested* archive is the only
/// row that reaches here and is refused, because its own bytes are already a temp copy and a repack
/// would have nowhere to land; F4 additionally drops the write bits on the copy it hands over, so
/// an edit fails visibly instead of being lost. That belongs to F4 rather than here: the same
/// extraction is what Open With, Share and a checksum read, and none of them is about to write.
extension PanelViewController {
    /// Where an edited copy of `entry` has to go back to, or `nil` when there is nowhere.
    ///
    /// `nil` for a file already on this disk — an editor's save lands on it directly and there is
    /// nothing to carry — which is what keeps every ordinary local gesture from registering a
    /// watcher it would never fire.
    func editDestination(for entry: FileEntry) -> EditDestination? {
        if let archivePath = entry.path.backend.archivePath {
            guard isWritableArchiveMember(entry) else { return nil }
            // The member's own directory inside the archive, taken from the **entry** rather than
            // from the pane: an edit can outlive the navigation that started it, and the pane may
            // be showing something else entirely by the time the save arrives.
            return .archiveMember(
                archivePath: archivePath,
                innerDirectory: entry.path.parent?.path ?? "/"
            )
        }
        return canEditRemoteFile(entry) ? .remoteFile(entry.path) : nil
    }

    /// Watch one copy for a save. A no-op for a row with nowhere to go back to, and for a copy
    /// already watched — opening a file with ⏎ and then running a script over it must leave one
    /// watcher on it rather than two questions on every save.
    func watchForWriteBack(of entry: FileEntry, at url: URL) {
        guard let destination = editDestination(for: entry) else { return }
        host?.editedFiles.watch(
            EditedFile(destination: destination, temporaryURL: url, name: entry.name)
        )
    }

    /// The same over a whole set, pairing rows with copies **positionally**.
    ///
    /// Positional is exact rather than convenient: `materialize` hands its URLs back in the order it
    /// was given its rows, and only when every one of them resolved — a short set is reported as a
    /// failure and never reaches a caller. The count check is what keeps that a property checked
    /// here instead of an assumption held in another file.
    func watchForWriteBack(of rows: [FileEntry], at urls: [URL]) {
        guard rows.count == urls.count else { return }
        for (row, url) in zip(rows, urls) {
            watchForWriteBack(of: row, at: url)
        }
    }
}
