import DirnexCore
import Foundation

/// Where an edited copy has to go back to — the one thing that differs between the two kinds of
/// "elsewhere" Dirnex can hand an editor a file out of (PLAN.md §M4, §M21 Slice 10).
///
/// Both kinds arrive at the same place: a file in a temp directory that an editor has open, whose
/// save has to be carried back to somewhere that is not a path on this Mac. Detecting that save is
/// identical work — watch the directory, compare the revision, offer once — so it is one mechanism
/// with two endings rather than two mechanisms that happen to look alike.
enum EditDestination: Hashable {
    /// Back into the archive it was extracted from, at the inner directory it came from.
    case archiveMember(archivePath: String, innerDirectory: String)
    /// Back up to the remote path it was downloaded from. Carries the whole `VFSPath`, so the
    /// backend id rides along and two accounts holding the same key cannot be confused for one.
    case remoteFile(VFSPath)
}

/// One file the user has opened for editing out of somewhere that is not this Mac, and where it has
/// to go back to.
struct EditedFile: Hashable {
    let destination: EditDestination
    /// The downloaded or extracted copy the editor has open.
    let temporaryURL: URL
    /// The file's name, for the confirmation the user reads.
    let name: String
}

/// Watches the copies of elsewhere-files the user has opened, and says when one has been saved
/// (PLAN.md §M4 "edit-temp-watch-repack write-back", extended by §M21 Slice 10).
///
/// Opening a file out of an archive — or off a server — hands an editor a copy in a temp directory,
/// so a save lands there and not where the file came from. Until this existed the app's answer was
/// to make the copy read-only for archives and to refuse outright for remote files: honest, and it
/// meant "you cannot edit files that aren't on this Mac". This is the other half: notice the save,
/// and offer to put it back.
///
/// **The watch is on the copy's temp *directory*, not the file.** Every extraction and every fetch
/// gets its own directory, and almost every macOS editor saves atomically — write a sibling, rename
/// over the original — so the file the editor leaves behind is a different inode from the one that
/// was opened. Anything holding a descriptor would sit watching a file nobody will ever write to
/// again, and would fail in the silent direction: no error, no callback, and the user's edit quietly
/// not offered. The price of watching the directory is that the editor's own scratch files wake it
/// too, which is what `EditedFileRevision` filters.
///
/// One registry per window, beside the preview caches and the passphrase store. It holds the
/// watchers for the life of the window: an edit may take an hour, and there is no moment before the
/// app quits at which "they must be finished by now" is true.
@MainActor
final class EditedFileRegistry {
    /// What is being watched, and the revision each file was last *known* at — updated on every
    /// offer, accepted or not, so declining once does not re-ask on the next unrelated event.
    private var watched: [URL: (edit: EditedFile, revision: EditedFileRevision?)] = [:]
    private var watchers: [URL: DirectoryWatcher] = [:]

    /// Called on the main actor when a watched copy has been saved. Set once by the window.
    var onEdited: ((EditedFile) -> Void)?

    /// Begin watching `edit`'s temp copy, recording what it looks like now so a later change can be
    /// told from the editor merely opening it. Watching the same copy twice is a no-op — reopening a
    /// file the user already has open must not stack a second watcher on it.
    func watch(_ edit: EditedFile) {
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

    /// Stop watching a copy — used when an archive write-back has landed, so the freshly repacked
    /// archive's own re-extraction starts from a clean slate rather than inheriting a stale revision.
    ///
    /// A **remote** write-back deliberately does *not* call this, which is the one place the two
    /// endings differ. Repacking replaces the archive, so the copy that was absorbed is finished
    /// with; an upload changes nothing on this Mac, and the editor still has that same file open. A
    /// second save must offer again, so the watch stays and only the revision it compares the
    /// *server* against is re-baselined.
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
