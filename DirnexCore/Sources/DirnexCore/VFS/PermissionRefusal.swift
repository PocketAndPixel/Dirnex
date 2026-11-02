import Foundation

/// What refused a ``VFSError/permissionDenied(_:refusedBy:)``, where the backend could tell.
///
/// A local refusal arrives as one of two errnos, and they call for different advice. `EACCES` is
/// the item's own permissions — its owner, its mode bits or an ACL — while macOS privacy protection
/// (TCC) refuses with `EPERM`. Measured 2026-10-30 from a probe app launched with `open`, so it was
/// its own responsible process rather than borrowing the shell's grant: `opendir`, `open` and
/// `access` on `~/Library/Mail`, `~/Library/Safari` and the TCC database all failed `EPERM`, while
/// another account's `drwx------` Documents failed `EACCES` (the shell, which has the grant, got
/// the same `EACCES` there). Full Disk Access lifts only the `EPERM`, and an administrator's
/// account gets the `EACCES` too until something acts as root.
public enum PermissionRefusal: Sendable, Equatable {
    /// Not established: a server's refusal, an `EPERM` no lock explains, or a Cocoa error with no
    /// errno under it. Such an `EPERM` stays here because TCC is only its most likely cause on a
    /// local disk, not its only one: `chown` to another user fails with it too.
    case unattributed
    /// The item's own permissions refused (`EACCES`). No grant to this app changes them; the
    /// owner, or an administrator acting as root, can.
    case itemPermissions
    /// The item, or the folder it is in, is locked: Finder's Locked (`UF_IMMUTABLE`) or the root-only
    /// `SF_IMMUTABLE`. The payload is whichever of the two carries the flag, so the sentence can name
    /// it. Read off the flags at the failure, since the errno is the same `EPERM` TCC gives
    /// (``notPermitted(at:flags:)``).
    case locked(VFSPath)
}

extension PermissionRefusal {
    /// What refused an `EPERM`, or Cocoa's write refusal, on this Mac's disk: ``locked(_:)`` when one of
    /// `paths` or the folder it is in is locked, and ``unattributed`` otherwise.
    ///
    /// Measured 2026-10-30 on `chflags uchg` fixtures: a create, a `mkdir`, a rename and an unlink
    /// inside a locked folder, a rename, an unlink and a write of a locked file, and a move *into* a
    /// locked folder all failed `EPERM`, while `FileManager.trashItem` failed with Cocoa's 513 over an
    /// OSStatus (-5000) and no errno at all. So the folder is checked as well as the item, and a move
    /// passes both of its ends: the folder that refuses one is the destination's.
    ///
    /// A path on another backend is never looked up here, whatever its spelling.
    static func notPermitted(
        at paths: [VFSPath],
        flags: (String) -> BSDFileFlags? = Self.flags(at:)
    ) -> PermissionRefusal {
        for path in paths where path.backend == .local {
            for candidate in [path, path.parent].compactMap(\.self)
                where flags(candidate.path)?.blocksModification == true {
                return .locked(candidate)
            }
        }
        return .unattributed
    }

    /// The flags word of the item at `path` itself (a symlink's own, not its target's), or `nil`
    /// when it cannot be read, as for the file a create was about to make.
    static func flags(at path: String) -> BSDFileFlags? {
        var info = stat()
        guard lstat(path, &info) == 0 else { return nil }
        return BSDFileFlags(rawValue: info.st_flags)
    }
}
