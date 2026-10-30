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
    /// Not established: a server's refusal, an `EPERM`, or a Cocoa error with no errno under it.
    /// `EPERM` stays here because TCC is only its most likely cause on a local disk, not its only
    /// one — `chown` to another user and a `UF_IMMUTABLE` item fail with it too.
    case unattributed
    /// The item's own permissions refused (`EACCES`). No grant to this app changes them; the
    /// owner, or an administrator acting as root, can.
    case itemPermissions
}
