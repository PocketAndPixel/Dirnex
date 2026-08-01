import Foundation

/// Which items a **recursive** attributes apply touches, and in what order (PLAN.md §M14 Slice 4) —
/// the pure half of ``AttributeApplyRunner``.
///
/// Split out for the reason ``ChecksumScope`` was: these are *decisions*, not I/O, and each one is
/// wrong in a specific, quiet, expensive way when got backwards. Two of the three were settled by
/// probing the real syscalls rather than by reading a man page, and the ordering rule below is the
/// one that decides whether the operation can complete at all.
public enum AttributeApplyScope {
    // MARK: - Which items

    /// Which kinds of enclosed item a run changes — Total Commander's shape, and it exists because
    /// the execute bit means opposite things on a file and on a directory.
    ///
    /// `chmod -R 0644` over a tree is the demonstration, and it is the *system tool* doing it:
    /// probed 2026-08-01, it leaves the root `drw-r--r--`, after which `ls` and `find` both fail.
    /// A single "apply to everything" switch hands the user that footgun; ``filesOnly`` then
    /// ``foldersOnly`` is how they say `rw-r--r--` for files and `rwxr-xr-x` for folders and mean it.
    public enum Target: String, Sendable, Equatable, Codable, CaseIterable {
        case everything
        case filesOnly
        case foldersOnly
    }

    /// Whether an enclosed item of this kind is changed by a run with this target.
    ///
    /// A symlink counts as a file, matching every other decision in the attributes machinery: the
    /// panel edits a link's own mode through the `l*` syscalls, and ``ACLRight/applicable(to:)``
    /// already offers it the file rights set.
    public static func includes(_ kind: FileEntry.Kind, target: Target) -> Bool {
        switch target {
        case .everything: return true
        case .filesOnly: return kind != .directory
        case .foldersOnly: return kind == .directory
        }
    }

    /// Whether the walk descends into an entry.
    ///
    /// Real directories only — **a symlink is never followed**, which is ``ChecksumScope``'s rule
    /// for the same two reasons: a link into an ancestor is a cycle with no end, and a link to a
    /// directory already in the tree would apply the change to the same items twice. Confirmed
    /// against `find`, which walks this tree as three files and not as an infinite one.
    public static func shouldDescend(into entry: FileEntry) -> Bool {
        entry.kind == .directory
    }

    // MARK: - The order — the rule that decides whether the run completes

    /// Whether the *roots* — the items the sheet was opened on — are always changed, whatever the
    /// target filter says.
    ///
    /// They are, and it is a deliberate reading rather than an oversight: the filter is about the
    /// items *inside*, which the user never saw, while a root is the thing they opened Get Info on
    /// and edited. Excluding the folder whose panel they just used because they also asked for
    /// "files only" would be surprising in the one direction that matters — silently not doing what
    /// the visible sheet said.
    public static let rootsAlwaysApply = true

    /// Order a gathered walk so it can actually be applied: **deepest item first, every root last.**
    ///
    /// This is the finding that shapes the whole operation, probed 2026-08-01, and it is not the
    /// obvious design. Applying to a directory *before* its children locks the run out of them:
    /// clearing a directory's `x` bit makes every child path fail to resolve, so a chmod of a
    /// grandchild comes back `EPERM` — and **gathering the child paths up front does not save it**,
    /// because the failure is in path resolution at apply time, not in the walk. Measured directly:
    /// with the child list already in hand, applying `0644` to the parent and then to each child
    /// gave "Permission denied" on every one of them.
    ///
    /// Post-order is the only order that finishes. The walk reads the tree while it is still
    /// readable and the changes land from the leaves up, so a mode that makes a directory
    /// unwalkable is written only once nothing needs to walk it again.
    ///
    /// Expressed over an already-gathered list rather than inside the walk so it is a rule with a
    /// test: sorting by descending depth is stable, so items at equal depth keep the walk's own
    /// order and a re-run over an unchanged tree applies in an identical sequence.
    public static func applicationOrder(of paths: [VFSPath]) -> [VFSPath] {
        paths.enumerated()
            .sorted { left, right in
                let leftDepth = depth(of: left.element)
                let rightDepth = depth(of: right.element)
                if leftDepth != rightDepth { return leftDepth > rightDepth }
                return left.offset < right.offset
            }
            .map(\.element)
    }

    /// How many components deep a path sits — the sort key behind ``applicationOrder(of:)``.
    static func depth(of path: VFSPath) -> Int {
        path.path.reduce(0) { $1 == "/" ? $0 + 1 : $0 }
    }
}
