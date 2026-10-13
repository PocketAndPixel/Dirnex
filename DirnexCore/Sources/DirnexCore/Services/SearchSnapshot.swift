import Foundation

/// A search's hits after the app deleted or moved some of them.
///
/// A search snapshot is the one listing that can neither re-list nor re-gather itself — it keeps the
/// hits it was given, which is right for the world changing underneath it and wrong for a change the
/// app made itself. So a delete or a move is applied to it by hand, the way an in-place rename is
/// (`substituteSearchHit` in the app). Two halves:
///
/// - ``applying(_:to:)`` — the rows a delete or a move took away, and the ones a queued rename
///   renamed where they stand.
/// - ``reconciled(_:departed:present:)`` — the rows that came back. A hit sent to the Trash or moved
///   away can be put back by ⌘Z, and the snapshot has to show it again, because a clean undo reports
///   nothing: the panes are supposed to reflect it already. It is decided by whether each departed
///   hit is at its path again (``present(_:using:)``), not by reading the undo record, so an undo
///   that put back only some, and the redo that sends them away again, need no branch of their own.
///
/// Only hits that can come back are worth following. A permanent delete cannot be undone, and
/// following every row would turn a snapshot into a live listing, which is a different feature with
/// a different cost.
public enum SearchSnapshot {
    /// What the app did to one hit.
    public enum Change: Sendable, Equatable {
        /// Deleted, permanently or to the Trash.
        case removed(VFSPath)
        /// Moved, landing at the second path. A landing in the hit's own folder is a rename — the
        /// shape a queued rename takes (an S3 prefix, a rename across devices) — and the row stays
        /// under its new name; anywhere else, the hit has left the place it was found.
        case moved(VFSPath, to: VFSPath)

        var source: VFSPath {
            switch self {
            case let .removed(path), let .moved(path, _): path
            }
        }
    }

    /// What applying changes to a snapshot produced.
    public struct Applied: Sendable, Equatable {
        /// The rows to show now.
        public let entries: [FileEntry]
        /// The rows that left, as they were — what a caller follows to bring a row back after ⌘Z.
        public let departed: [FileEntry]
    }

    /// `entries` after `changes`, or `nil` when none of them touches a row the snapshot holds. Order
    /// is kept; a path the snapshot does not hold — a row inside an expanded folder, which its own
    /// re-list handles — changes nothing.
    public static func applying(_ changes: [Change], to entries: [FileEntry]) -> Applied? {
        let bySource = Dictionary(
            changes.map { ($0.source, $0) },
            uniquingKeysWith: { _, last in last }
        )
        var shown: [FileEntry] = []
        var departed: [FileEntry] = []
        for entry in entries {
            switch bySource[entry.path] {
            case nil:
                shown.append(entry)
            case let .moved(source, to: landing)?
                where landing.backend == source.backend && landing.parent == source.parent:
                shown.append(entry.renamed(to: landing.lastComponent))
            case .removed?, .moved?:
                departed.append(entry)
            }
        }
        guard shown != entries else { return nil }
        return Applied(entries: shown, departed: departed)
    }

    /// What a finished queue job did to the hits it was handed: each item a **move** relocated, from
    /// the report's own outcomes. A copy leaves its sources where they were, and a skipped item
    /// (`landedAt == nil`) or a failed one never moved, so none of those is a change.
    ///
    /// Read from `outcomes` rather than from the job's sources because a move can stop partway — a
    /// Stop, an Abort, a conflict answered with Skip — and a row whose file is still there must
    /// stay. An outcome is recorded only once the source has been removed, so it is exactly what
    /// left (`CopyEngine.attempt`).
    public static func changes(made report: OperationReport, by kind: FileOperation.Kind) -> [Change] {
        guard case .move = kind else { return [] }
        return report.outcomes.compactMap { outcome in
            outcome.landedAt.map { Change.moved(outcome.source, to: $0) }
        }
    }

    /// `entries` with every departed hit shown exactly when it is `present` at its path again, or
    /// `nil` when that is what `entries` already shows — so a caller can skip a reload that would
    /// redraw identical rows.
    ///
    /// A returning hit is shown as it was when it left. An undo moves the item back whole, so that
    /// is what is on disk; anything that changed it since is the world changing underneath a
    /// snapshot, which a snapshot does not follow.
    public static func reconciled(
        _ entries: [FileEntry],
        departed: [FileEntry],
        present: Set<VFSPath>
    ) -> [FileEntry]? {
        var gone = Set<VFSPath>()
        var returning: [VFSPath: FileEntry] = [:]
        for hit in departed {
            if present.contains(hit.path) {
                returning[hit.path] = hit
            } else {
                gone.insert(hit.path)
            }
        }
        let shown = Set(entries.map(\.path))
        let kept = entries.filter { !gone.contains($0.path) }
        let added = departed.filter { hit in
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
