import Foundation

/// A network share's own recycle bin — the `#recycle` directory Samba's `vfs_recycle` module keeps,
/// which is what a Synology NAS puts deleted files into (PLAN.md §M8 restore, extended 2026-09-20).
///
/// **The path is the metadata, which is what makes this simpler than Finder's Put Back.** Measured
/// 2026-09-20 against a live DSM share mounted over SMB: deleting `probe/sub/nested.txt` from the
/// share root left it at `#recycle/probe/sub/nested.txt` — the original path relative to the bin's
/// **parent**, reproduced as real directories. So there is no database to read and nothing that can
/// go stale: where an item came from is where it physically sits, and restoring it is a move to the
/// same relative path one level up. Contrast ``TrashPutBack``, which has to parse a `.DS_Store`
/// B-tree because macOS records the origin nowhere else, and which answers `nil` for every item
/// Finder never wrote a record for.
///
/// **Relative to the bin's parent, not to the volume root**, and that distinction is load-bearing
/// rather than pedantic: DSM keeps one bin per *shared folder*, so mounting the `home` share puts
/// `#recycle` at the volume root while mounting `homes` puts one at `homes/<user>/#recycle`, a level
/// down. A rule anchored on the volume would restore the second case into the wrong folder. The
/// parent answers both, at any depth, with no knowledge of how the share was mounted.
///
/// **Deliberately pure**, like ``TrashLocations``: every function here is a path computation that
/// touches no disk, so the gate that offers the gesture costs nothing on a row the cursor merely
/// passed over.
///
/// **This is not a macOS trash and must not become one.** ``TrashLocations/isInsideTrash(_:)`` is
/// what withdraws `.trash` and `.rename` from a location and what pulls it into the merged `trash:`
/// listing; a `#recycle` directory is granted none of that on purpose. It belongs to the *server*
/// rather than to this Mac — it exists only while the share is mounted, DSM alone decides what
/// lands in it, and rename inside it works and was measured working. What it takes from the trash
/// machinery is one value type, ``TrashOrigin``, which is what lets the restore inherit the rules
/// that flow already keeps: never overwrite, recreate a folder that has since been deleted, and let
/// one failure not abandon the rest.
public enum ShareRecycleBin {
    /// DSM's name for the bin, and `vfs_recycle`'s default.
    ///
    /// One spelling only, and **no attempt at other vendors'**. QNAP's equivalent is `@Recycle`,
    /// whose contents this code has never been pointed at — whether it mirrors the path the same
    /// way is unmeasured, and a wrong guess here restores a file to a folder nobody named. Adding it
    /// is a string in this file plus a probe against a real QNAP, in that order.
    public static let directoryName = "#recycle"

    /// Whether `path` is an item **inside** a recycle bin — which is the question the Put Back gate
    /// asks, and it is deliberately not "is this a bin".
    ///
    /// False for the bin directory itself: that row is an ordinary folder sitting in the share, and
    /// putting it "back" would mean moving the bin out of the share it belongs to.
    public static func holds(_ path: VFSPath) -> Bool {
        origin(of: path) != nil
    }

    /// The bin that governs deletes on a mounted share, which sits at the share's own root.
    ///
    /// `vfs_recycle` is configured **per share**, so the bin that catches a delete is the one at the
    /// root of the share the file was reached through — for a mounted volume, its mount point. That
    /// is a different question from ``binRoot(of:)``, which asks where an item *already in* a bin is
    /// sitting, and the two part company on a share whose tree holds a second `#recycle` further
    /// down (a `homes` mount, where each user's folder kept one from when it was shared itself).
    ///
    /// Pure, like the rest of this type: whether the directory is there is the caller's to check,
    /// beside the other "only what exists" questions in the app.
    public static func bin(atShareRoot root: VFSPath) -> VFSPath {
        root.appending(directoryName)
    }

    /// The bin an item is sitting in — what a restore prunes its leftover scaffolding back up to.
    ///
    /// - Returns: `nil` for a path in no bin, and for a bin directory itself, so it answers for
    ///   exactly the paths ``holds(_:)`` does.
    public static func binRoot(of path: VFSPath) -> VFSPath? {
        let components = path.path
            .split(separator: "/", omittingEmptySubsequences: true)
            .map(String.init)
        guard let bin = components.firstIndex(of: directoryName),
              components.index(after: bin) < components.endIndex
        else {
            return nil
        }
        return VFSPath(
            backend: path.backend,
            path: "/" + components[...bin].joined(separator: "/")
        )
    }

    /// Where the item goes back to: the folder it was deleted from, and the name it had there.
    ///
    /// Reuses ``TrashOrigin`` so the app's one restore flow serves both sources — see the type's own
    /// note on why the name travels separately from the folder. Here the two always agree, because
    /// nothing renames an item on its way into a `#recycle` (DSM mirrors the path instead of
    /// stamping the name the way a macOS trash does on a collision); carrying it anyway is what
    /// lets the caller stay one code path.
    ///
    /// - Returns: `nil` when no component is a recycle bin, and when the bin holds no item below it
    ///   — the bin itself, or a path that merely ends at one.
    public static func origin(of path: VFSPath) -> TrashOrigin? {
        let components = path.path
            .split(separator: "/", omittingEmptySubsequences: true)
            .map(String.init)
        // The **first** bin wins. A folder someone deleted that was itself called `#recycle` lands
        // at `#recycle/#recycle`, and it goes back to `<parent>/#recycle`: taking the last
        // occurrence instead would restore it into the bin it is sitting in.
        guard let bin = components.firstIndex(of: directoryName) else { return nil }
        let inside = components[components.index(after: bin)...]
        guard let name = inside.last else { return nil }

        let directory = components[..<bin] + inside.dropLast()
        return TrashOrigin(
            directory: VFSPath(backend: path.backend, path: "/" + directory.joined(separator: "/")),
            name: name
        )
    }
}
