import AppKit

/// The one place a saved copy is routed to whichever kind of elsewhere it came from (PLAN.md §M4
/// write-back, §M21 Slice 10).
///
/// `EditedFileRegistry` detects the save and knows nothing about what to do with it; the two arms
/// live in `+ArchiveWriteBack` and `+RemoteWriteBack`. Having the switch here rather than inside the
/// registry is what keeps the *detection* free of both endings — the registry is a watcher, and a
/// watcher that knew about archives and about `curl` would be two features wearing one type.
extension BrowserWindowController {
    /// A watched copy has been saved — offer to put it back where it came from.
    func offerWriteBack(_ edit: EditedFile) {
        switch edit.destination {
        case let .archiveMember(archivePath, innerDirectory):
            offerArchiveWriteBack(edit, archivePath: archivePath, innerDirectory: innerDirectory)
        case let .remoteFile(path):
            offerRemoteWriteBack(edit, to: path)
        }
    }
}
