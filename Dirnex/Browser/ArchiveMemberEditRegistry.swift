import DirnexCore
import Foundation

/// One archive member the user has opened for editing, and where it has to go back to.
struct ArchiveMemberEdit: Hashable {
    /// The archive on disk that owns the member.
    let archivePath: String
    /// The member's inner directory (`/` = the archive root) — where the write-back adds it.
    let innerDirectory: String
    /// The extracted copy the editor has open.
    let temporaryURL: URL
    /// The member's name, for the confirmation the user reads.
    let name: String
}

/// Watches the copies of archive members the user has opened, and says when one has been saved
/// (PLAN.md §M4 "edit-temp-watch-repack write-back").
///
/// Opening a file out of an archive hands an editor a copy in a temp directory, so a save lands
/// there and not in the archive. Until this existed the app's answer was to make the copy read-only
/// — honest, but it meant "you cannot edit files in an archive". This is the other half: notice the
/// save, and offer to put it back.
///
/// **The watch is on the member's temp *directory*, not the file.** Every extraction already gets
/// its own directory, and almost every macOS editor saves atomically — write a sibling, rename over
/// the original — so the file the editor leaves behind is a different inode from the one that was
/// opened. Anything holding a descriptor would sit watching a file nobody will ever write to again,
/// and would fail in the silent direction: no error, no callback, and the user's edit quietly not
/// offered. The price of watching the directory is that the editor's own scratch files wake it too,
/// which is what `EditedFileRevision` filters.
///
/// One registry per window, beside the preview cache and the passphrase store. It holds the watchers
/// for the life of the window: an edit may take an hour, and there is no moment before the app quits
/// at which "they must be finished by now" is true.
@MainActor
final class ArchiveMemberEditRegistry {
    /// What is being watched, and the revision each file was last *known* at — updated on every
    /// offer, accepted or not, so declining once does not re-ask on the next unrelated event.
    private var watched: [URL: (edit: ArchiveMemberEdit, revision: EditedFileRevision?)] = [:]
    private var watchers: [URL: DirectoryWatcher] = [:]

    /// Called on the main actor when a watched member has been saved. Set once by the window.
    var onEdited: ((ArchiveMemberEdit) -> Void)?

    /// Begin watching `edit`'s temp copy, recording what it looks like now so a later change can be
    /// told from the editor merely opening it. Watching the same copy twice is a no-op — reopening a
    /// member the user already has open must not stack a second watcher on it.
    func watch(_ edit: ArchiveMemberEdit) {
        guard watchers[edit.temporaryURL] == nil else { return }
        watched[edit.temporaryURL] = (
            edit, EditedFileRevision.current(ofFileAt: edit.temporaryURL.path)
        )
        let directory = edit.temporaryURL.deletingLastPathComponent()
        let url = edit.temporaryURL
        watchers[url] = DirectoryWatcher(path: .local(directory.path)) { [weak self] in
            // FSEvents delivers on its own queue; every decision below reads main-actor state.
            Task { @MainActor in self?.directoryChanged(for: url) }
        }
    }

    /// Stop watching a member — used when a write-back has landed, so the freshly repacked archive's
    /// own re-extraction starts from a clean slate rather than inheriting a stale revision.
    func stopWatching(_ temporaryURL: URL) {
        watchers[temporaryURL]?.stop()
        watchers[temporaryURL] = nil
        watched[temporaryURL] = nil
    }

    /// Re-read the watched file and, if it is genuinely a later revision, report it once.
    ///
    /// The revision is advanced *before* `onEdited` runs, not after the user answers: the offer is
    /// asynchronous (a sheet), and an editor that autosaves twice while it is up would otherwise
    /// queue a second identical question behind the first.
    private func directoryChanged(for temporaryURL: URL) {
        guard let entry = watched[temporaryURL],
              let current = EditedFileRevision.current(ofFileAt: temporaryURL.path)
        else { return }
        // No recorded revision means the file was gone when watching began — nothing to compare, so
        // adopt what is there now rather than treating its arrival as an edit.
        guard let previous = entry.revision else {
            watched[temporaryURL] = (entry.edit, current)
            return
        }
        guard previous.isSuperseded(by: current) else { return }
        watched[temporaryURL] = (entry.edit, current)
        onEdited?(entry.edit)
    }
}
