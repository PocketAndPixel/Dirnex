import Foundation

/// A search's hits after the pane showing them deleted some.
///
/// A search snapshot is the one listing that can neither re-list nor re-gather itself — it keeps the
/// hits it was given, which is right for the world changing underneath it and wrong for a change the
/// pane made itself. So a delete performed in one is applied to it by hand, the way a rename is
/// (`substituteSearchHit` in the app). Two halves:
///
/// - ``removing(_:from:)`` — the rows a delete took away.
/// - ``reconciled(_:trashed:present:)`` — the rows that came back. A hit sent to the Trash can be
///   put back by ⌘Z, and the snapshot has to show it again, because a clean undo reports nothing:
///   the panes are supposed to reflect it already. It is decided by whether each trashed hit is at
///   its path again (``present(_:using:)``), not by reading the undo record, so an undo that put back
///   only some, and the redo that sends them away again, need no branch of their own.
///
/// Only hits the pane sent to the **Trash** are worth following. A permanent delete cannot be
/// undone, and following every row would turn a snapshot into a live listing, which is a different
/// feature with a different cost.
public enum SearchSnapshot {
    /// `entries` without the rows at `paths`. Order is kept; a path the snapshot does not hold —
    /// a row inside an expanded folder, which its own re-list handles — changes nothing.
    public static func removing(
        _ paths: some Sequence<VFSPath>,
        from entries: [FileEntry]
    ) -> [FileEntry] {
        let removed = Set(paths)
        return entries.filter { !removed.contains($0.path) }
    }

    /// `entries` with every trashed hit shown exactly when it is `present` at its path again, or
    /// `nil` when that is what `entries` already shows — so a caller can skip a reload that would
    /// redraw identical rows.
    ///
    /// A returning hit is shown as it was when it was deleted. An undo moves the item back whole, so
    /// that is what is on disk; anything that changed it since is the world changing underneath a
    /// snapshot, which a snapshot does not follow.
    public static func reconciled(
        _ entries: [FileEntry],
        trashed: [FileEntry],
        present: Set<VFSPath>
    ) -> [FileEntry]? {
        var gone = Set<VFSPath>()
        var returning: [VFSPath: FileEntry] = [:]
        for hit in trashed {
            if present.contains(hit.path) {
                returning[hit.path] = hit
            } else {
                gone.insert(hit.path)
            }
        }
        let shown = Set(entries.map(\.path))
        let kept = entries.filter { !gone.contains($0.path) }
        let added = trashed.filter { hit in
            !shown.contains(hit.path) && returning.removeValue(forKey: hit.path) != nil
        }
        guard kept.count != entries.count || !added.isEmpty else { return nil }
        return kept + added
    }

    /// Which of `paths` exist again, asked through the backend that owns them.
    ///
    /// `stat` rather than `FileManager.fileExists`, which follows a symlink: a trashed link whose
    /// target is gone would read as missing after ⌘Z had put it back.
    public static func present(
        _ paths: some Sequence<VFSPath>,
        using backend: any VFSBackend
    ) -> Set<VFSPath> {
        Set(paths.filter { (try? backend.stat(at: $0)) != nil })
    }
}
