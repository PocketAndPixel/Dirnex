import AppKit

/// The one place a saved copy is routed to whichever kind of elsewhere it came from (PLAN.md §M4
/// write-back, §M21 Slice 10).
///
/// `EditedFileRegistry` detects the save and knows nothing about what to do with it; the two arms
/// live in `+ArchiveWriteBack` and `+WriteBackBatch`. Having the switch here rather than inside the
/// registry is what keeps the *detection* free of both endings — the registry is a watcher, and a
/// watcher that knew about archives and about `curl` would be two features wearing one type.
///
/// **The switch moved from the edit to the batch on 2026-09-01**, and that is the whole of what
/// changed here: saves are gathered first and split afterwards, so the two endings share one pacing
/// rule instead of each growing a copy of it. A script that rewrites forty files produces forty
/// saves whichever kind they are, and both endings were paying for that one at a time — the remote
/// one in forty uploads, the archive one in forty full repacks of the same container.
extension BrowserWindowController {
    /// A watched copy has been saved — put it in the next batch.
    ///
    /// Replacing rather than appending a second entry for the same copy: an editor that autosaves
    /// twice before a batch opens has one file to put back, and its *newer* bytes are the ones that
    /// should go.
    func offerWriteBack(_ edit: EditedFile) {
        pendingWriteBacks.removeAll { $0.temporaryURL == edit.temporaryURL }
        pendingWriteBacks.append(edit)
        guard !isGatheringWriteBacks else { return }
        isGatheringWriteBacks = true
        Task { await gatherWriteBacks() }
    }
}
