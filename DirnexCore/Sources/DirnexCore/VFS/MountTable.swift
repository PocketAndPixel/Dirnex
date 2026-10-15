import Foundation

/// One mounted file system, as the kernel's mount table lists it.
public struct MountTableEntry: Sendable, Hashable {
    /// Where the file system is mounted — `/`, `/Volumes/NAS`.
    public let mountPoint: String
    /// Whether it is stored on this Mac's own hardware (`MNT_LOCAL`): `true` for the boot disk, an
    /// external drive and a mounted disk image alike, `false` for a share — SMB, AFP, NFS, WebDAV.
    public let isLocal: Bool
    /// Whether the file system is one Finder lists (`MNT_DONTBROWSE` absent) — `false` for `/dev`, a
    /// simulator runtime, and a vault attached hidden. The sidebar's Volumes section lists exactly
    /// these.
    public let isBrowsable: Bool

    public init(mountPoint: String, isLocal: Bool, isBrowsable: Bool = true) {
        self.mountPoint = mountPoint
        self.isLocal = isLocal
        self.isBrowsable = isBrowsable
    }
}

/// The kernel's list of mounted file systems, and which of them a path lies on.
///
/// Read with `MNT_NOWAIT`, which hands back the kernel's own copy of each file system's statistics
/// without asking the file system for fresh ones. That is the property that makes it safe to ask on
/// the main thread: `URL.resourceValues` for a volume key resolves the path itself, which blocks
/// for as long as a share whose server has gone away does, while this answers in a few microseconds
/// whatever state the share is in (measured 2026-10-15: 3 µs for 13 mounts).
public enum MountTable {
    /// Every mounted file system right now.
    ///
    /// `getmntinfo_r_np` rather than `getmntinfo`, whose buffer is static and shared with every
    /// other caller in the process: the `_r_np` variant allocates one for this call alone.
    public static func current() -> [MountTableEntry] {
        var buffer: UnsafeMutablePointer<statfs>?
        let count = getmntinfo_r_np(&buffer, MNT_NOWAIT)
        guard count > 0, let buffer else { return [] }
        defer { free(buffer) }
        return UnsafeBufferPointer(start: buffer, count: Int(count)).compactMap { entry in
            var mountPoint = entry.f_mntonname
            // A mount point the kernel spells in something other than UTF-8 is one no `VFSPath` can
            // name either, so it could never be the answer for one.
            let path = withUnsafeBytes(of: &mountPoint) { bytes in
                String(bytes: bytes.prefix { $0 != 0 }, encoding: .utf8)
            }
            guard let path else { return nil }
            return MountTableEntry(
                mountPoint: path,
                isLocal: entry.f_flags & UInt32(MNT_LOCAL) != 0,
                isBrowsable: entry.f_flags & UInt32(MNT_DONTBROWSE) == 0
            )
        }
    }

    /// The file system `path` lies on: of the mount points that are `path` or one of its ancestors,
    /// the deepest — so `/Volumes/NAS/Photos` is on the share mounted at `/Volumes/NAS`, not on `/`.
    ///
    /// Lexical, on whole path components: `/Volumes/NASBackup` is not inside `/Volumes/NAS`. Nothing
    /// is resolved, so a path that reaches a volume only through a symlink is answered for where it
    /// is spelled — which is also what lets this answer for a path that no longer exists.
    public static func entry(
        containing path: String,
        in entries: [MountTableEntry]
    ) -> MountTableEntry? {
        entries
            .filter { contains($0.mountPoint, path) }
            .max { $0.mountPoint.count < $1.mountPoint.count }
    }

    /// Whether the volume mounted at `mountPoint` is built-in storage — the split the sidebar's
    /// Volumes section draws as `internaldrive` against `externaldrive`.
    ///
    /// A key the volume does not answer counts as external, exactly as `SidebarLocations.volumes`
    /// reads it: measured 2026-10-15, a mounted disk image reports `volumeIsInternal` as **nil**
    /// rather than `false`, and the sidebar draws it as an external drive.
    public static func isInternalVolume(at mountPoint: String) -> Bool {
        let values = try? URL(fileURLWithPath: mountPoint).resourceValues(
            forKeys: [.volumeIsInternalKey]
        )
        return values?.volumeIsInternal ?? false
    }

    private static func contains(_ mountPoint: String, _ path: String) -> Bool {
        if mountPoint == "/" { return path.hasPrefix("/") }
        return path == mountPoint || path.hasPrefix(mountPoint + "/")
    }
}
