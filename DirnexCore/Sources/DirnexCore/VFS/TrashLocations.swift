import Foundation

/// Where the Trash actually lives, and how to tell that you are standing in one (PLAN.md §M8
/// "Trash row").
///
/// macOS has no single Trash. The boot volume's is `~/.Trash`; every *other* mounted volume keeps
/// its own at `<volume>/.Trashes/<uid>`, one directory per user. Finder hides that behind a single
/// Trash icon, which is why the sidebar's row opens a **merged** listing rather than pointing at one
/// directory — a single row aimed at `~/.Trash` would be a lie the moment a drive is plugged in.
///
/// Deliberately pure: every function here is a path computation that touches no disk. The
/// existence-filtered enumeration lives in `SidebarLocations.trashDirectories` beside the other
/// "only what exists" sidebar enumerators, the same split `standardKind(for:)` draws against
/// `favorites()`.
public enum TrashLocations {
    /// The per-volume trash container's name. Every user's trash on that volume is a numbered
    /// subdirectory of it.
    ///
    /// Probed 2026-07-21: the container itself is mode `d-wx--x--t` — **not listable even by its
    /// own owner** — while `<container>/<uid>` inside it is a normal `drwx------`. So a volume's
    /// trash has to be constructed and opened directly; enumerating the parent to find it fails.
    /// Exactly the leaf-not-parent shape the iCloud container had in pass 6.
    public static let volumeContainer = ".Trashes"

    /// The boot volume's trash for the current user: `~/.Trash`. Reading it needs Full Disk
    /// Access — without the grant it comes back `NSCocoaErrorDomain` 257 (probed).
    public static func homeTrash(home: String = NSHomeDirectory()) -> VFSPath {
        VFSPath.local(home).appending(".Trash")
    }

    /// A non-boot volume's trash for one user: `<volume>/.Trashes/<uid>`.
    ///
    /// Spelled out by hand rather than asked of `FileManager.url(for: .trashDirectory,
    /// appropriateFor:)`, because that API cannot answer the question. Probed 2026-07-21 against a
    /// real mounted volume: it throws `NSFeatureUnsupportedError` (3328, "the feature is not
    /// supported") for a volume that simply has *nothing trashed yet*, and only starts returning
    /// the path once the directory exists. Trusting it would have read as "external volumes have no
    /// Trash" — a wrong answer in the quiet direction, since the row would just never appear.
    public static func volumeTrash(onVolumeAt volumeRoot: VFSPath, uid: uid_t = getuid()) -> VFSPath {
        volumeRoot.appending(volumeContainer).appending(String(uid))
    }

    /// Whether `path` is a trash directory or lies inside one — the predicate that inverts the
    /// delete semantics (PLAN.md §M8: "delete-inside-Trash must invert the default move-to-Trash
    /// semantics or it is a no-op loop").
    ///
    /// That loop is real, not theoretical: probed 2026-07-21, `FileManager.trashItem` on an item
    /// **already in the trash** reports *success* and hands back the very path it was given. F8 in
    /// the Trash would therefore look like it worked and change nothing — the quietest possible
    /// failure. The app drops the `.trash` capability for any path this returns `true` for, so the
    /// existing capability degradation (PLAN.md §M5) turns F8 into a confirmed permanent delete
    /// without a single special case in the delete path.
    ///
    /// Pure and lexical, like `standardKind(for:)`: it must answer for a path that no longer exists
    /// (the item was just deleted) and must not cost a `stat` on every keystroke-driven menu
    /// validation.
    ///
    /// Any user's numbered trash counts, not just the current one. The asymmetry is deliberate: a
    /// false positive costs a confirmation dialog on a delete, while a false negative is the silent
    /// no-op above.
    public static func isInsideTrash(_ path: VFSPath, home: String = NSHomeDirectory()) -> Bool {
        guard path.backend == .local else { return false }
        if path.isSelfOrDescendant(of: homeTrash(home: home)) { return true }
        return isInsideVolumeTrash(path)
    }

    /// The `<...>/.Trashes/<digits>` half of `isInsideTrash`, matched on components so that a folder
    /// merely *named* `.Trashes` (with no numbered user directory under it) doesn't qualify.
    private static func isInsideVolumeTrash(_ path: VFSPath) -> Bool {
        let components = path.path.split(separator: "/", omittingEmptySubsequences: true)
        return components.indices.contains { index in
            components[index] == volumeContainer
                && index + 1 < components.count
                && isUserIdentifier(components[index + 1])
        }
    }

    private static func isUserIdentifier(_ component: Substring) -> Bool {
        !component.isEmpty && component.allSatisfy(\.isNumber)
    }
}
