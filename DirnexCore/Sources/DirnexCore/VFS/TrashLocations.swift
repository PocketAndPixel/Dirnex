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

    /// What a trash directory is called everywhere except a volume container, whose numbered
    /// subdirectories sit under `volumeContainer` instead.
    public static let trashDirectoryName = ".Trash"

    /// The boot volume's trash for the current user: `~/.Trash`. Reading it needs Full Disk
    /// Access — without the grant it comes back `NSCocoaErrorDomain` 257 (probed).
    public static func homeTrash(home: String = NSHomeDirectory()) -> VFSPath {
        VFSPath.local(home).appending(trashDirectoryName)
    }

    /// iCloud Drive's own trash: `~/Library/Mobile Documents/.Trash`.
    ///
    /// **A third shape, and it is neither of the other two** (probed 2026-07-21, after a folder
    /// deleted from iCloud Drive showed up in Finder's Trash and not in Dirnex's). Deleting inside
    /// iCloud Drive does not land in `~/.Trash`: the file provider keeps its own trash beside the
    /// containers — a *sibling* of `com~apple~CloudDocs`, not a child of it — with no `<uid>`
    /// subdirectory, since the container is already per-user (`drwx------`). Finder merges it into
    /// the one Trash it shows, so Dirnex's merged listing has to as well, or a delete from iCloud
    /// Drive vanishes into a Trash that reports itself empty.
    ///
    /// Reading it needs Full Disk Access — the enclosing `~/Library/Mobile Documents` is TCC-gated,
    /// and only the CloudDocs leaf inside it is carved out (docs/NOTES.md). Like the volume trashes
    /// it is *constructed* rather than discovered by enumerating that parent.
    public static func iCloudTrash(home: String = NSHomeDirectory()) -> VFSPath {
        VFSPath.local(home)
            .appending("Library")
            .appending("Mobile Documents")
            .appending(trashDirectoryName)
    }

    /// A `~/Library/CloudStorage` provider mount's own trash: `<mount>/.Trash`.
    ///
    /// **A fourth place, and the same shape as iCloud's** (probed 2026-07-22, after a file deleted
    /// from Google Drive showed up in Finder's Trash and not in Dirnex's — the identical report that
    /// found the iCloud trash a day earlier). Deleting inside such a mount does not land in
    /// `~/.Trash`: the mount keeps a `.Trash` of its own at its root, with no `<uid>` level, since
    /// a mount is already per-account. Finder merges them all into the one Trash it shows.
    ///
    /// There is **one per account, not one per provider** — two Google Drive accounts are two mounts
    /// and two trashes — which is why this takes a mount rather than computing a single path.
    ///
    /// **Not every provider does this, so the caller must filter on existence rather than trust the
    /// path.** Measured 2026-08-17 against a live OneDrive mount: it has no `.Trash` and never grows
    /// one (its domain answers Cocoa 3328, *"the feature is not supported"*, for its own trash
    /// enumeration), and a `trashItem` there succeeds by moving the file out of the provider domain
    /// into `~/.Trash` — which the merged listing already covers. `SidebarLocations.trashDirectories`
    /// is where that filter lives; this function stays a pure path computation.
    ///
    /// **And existence is not sufficient either: Dropbox has the directory and does not use it.**
    /// Measured 2026-08-18 — `Dropbox-Home` carries a `.Trash` at its root with the marker xattr
    /// below *and* a live `.trash` node in its domain, so every signal this code keys on says the
    /// provider keeps a trash; a `trashItem` on a file inside the mount nonetheless answers
    /// `~/.Trash`, and so does Finder's own delete, which names that destination itself. The control
    /// that makes it a claim about the provider rather than about the caller ran in the same binary
    /// on the same afternoon: a streaming-mode Google Drive mount answers `<mount>/.Trash` for both.
    /// So the row Dropbox contributes here is a directory that stays empty — one `readdir` on the
    /// merged listing and nothing on screen, since the Trash is one row over many sources rather
    /// than one row each. Nothing to fix; worth knowing before reading an empty Dropbox trash as a
    /// bug in the merge.
    ///
    /// **And Box says the filter's answer is not even stable.** Measured 2026-08-18, minutes after
    /// the domain was created: `Box-Box/.Trash` was on disk with the marker xattr, `SF_DATALESS`,
    /// 65535 links and a reconciled `.trash` node — then thirteen minutes later that node had failed
    /// `fetch-children-metadata` twice with the same Cocoa 3328 OneDrive gives, and the directory was
    /// gone from the filesystem for good. A `stat` reaching into it during the changeover returned
    /// `ETIMEDOUT`. So the caller filters a property that *changes*, and the window where it answers
    /// yes is the first quarter-hour after somebody installs the client. It degrades correctly rather
    /// than by luck: `ETIMEDOUT` has no case in `VFSError.fromErrno` and so lands on `.io`, which
    /// `gatherTrash` drops with `continue` — had it mapped to `.permissionDenied` instead, a Box
    /// trash timing out would have raised the Full Disk Access sheet at a user whose grant is fine.
    ///
    /// That these are the same species as iCloud's is not inference: all three carry the marker
    /// xattr `com.apple.fileprovider.trash`, and `~/.Trash` does not. They are constructed rather
    /// than discovered by that xattr because the mounts are already enumerated for the sidebar and a
    /// path is free, whereas a `getxattr` sweep is not.
    ///
    /// Unlike the iCloud trash this needs **no** Full Disk Access — `~/Library/CloudStorage` is not
    /// TCC-gated (docs/NOTES.md), so a Drive delete is visible in the merged Trash even on a Mac that
    /// has never seen the onboarding sheet.
    public static func cloudStorageTrash(inMountAt mount: VFSPath) -> VFSPath {
        mount.appending(trashDirectoryName)
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
        // iCloud's own trash counts for the same reason the others do: `trashItem` on something
        // already in a trash succeeds and does nothing, so F8 here has to become a real delete.
        if path.isSelfOrDescendant(of: iCloudTrash(home: home)) { return true }
        // And every provider mount's trash, for that same reason — one per account.
        if isInsideCloudStorageTrash(path, home: home) { return true }
        return isInsideVolumeTrash(path)
    }

    /// The `~/Library/CloudStorage/<mount>/.Trash` half of `isInsideTrash`.
    ///
    /// Matched positionally rather than by naming the mounts, so it stays pure: this must answer for
    /// a path whose item was just deleted, and must not `readdir` the provider directory on every
    /// menu validation. `.Trash` has to sit **exactly one level below** the CloudStorage root — a
    /// `.Trash` the user made inside their own Drive folder is an ordinary directory, not a trash,
    /// and treating it as one would turn F8 there into a permanent delete.
    private static func isInsideCloudStorageTrash(_ path: VFSPath, home: String) -> Bool {
        let root = CloudStorageMounts.cloudStorage(home: home)
        guard path.isSelfOrDescendant(of: root) else { return false }
        let rootDepth = root.path.split(separator: "/", omittingEmptySubsequences: true).count
        let components = path.path.split(separator: "/", omittingEmptySubsequences: true)
        // rootDepth is the mount name; the component after it is the one that must be `.Trash`.
        guard components.count > rootDepth + 1 else { return false }
        return components[rootDepth + 1] == trashDirectoryName
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
