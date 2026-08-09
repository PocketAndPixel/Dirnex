import Foundation

/// Which paths are inside an unlocked vault — so that nothing Dirnex remembers *implicitly* keeps
/// them after it locks (PLAN.md §M19, and the §6 risk row this closes).
///
/// ## What this is for, which is not what the risk originally said
///
/// §6 named three leaks a vault was expected to have — Spotlight's index, Quick View's caches and
/// the thumbnail store — and asked for them to be stated rather than passed over in silence.
/// Measured on macOS 26 against a real encrypted sparsebundle, none of the three is real:
///
/// - **Spotlight does not index a disk-image volume at all.** `mdutil -s` on the mounted volume
///   reports `Indexing disabled`, no `.Spotlight-V100` is created, and `mdfind` over the volume
///   returns nothing. Two controls make that meaningful: the boot volume reports `Indexing enabled`
///   in the same run, and an *unencrypted* sparsebundle is also disabled — so it is a property of
///   disk images, not something encryption is buying, and it is not something Dirnex arranged.
/// - **Nothing was cached for a thumbnail.** After a real `QLThumbnailGenerator` request against a
///   file on the volume (which produced a thumbnail), no file anywhere under the user's caches
///   directory named it, and the thumbnail agent's own store held nothing. Nothing survived the
///   detach.
///
/// What *is* real is Dirnex's own memory, which the risk did not think to name. Three stores write
/// paths to `UserDefaults` in the clear as a side effect of ordinary browsing: the frecency index
/// records every local directory visited, and a pane's persisted tabs carry the directory, the
/// cursor's file name, the marked names and the expanded folders. A vault's whole promise is that
/// locking it puts its contents beyond reach, and a list of the file names that were in it — written
/// by the file manager, sitting outside the encrypted image — is exactly the shape of thing that
/// promise is about. This type is the predicate those stores ask.
///
/// ## The line it draws
///
/// **Implicit memory only.** A store the user did not ask for — frecency, session restore — must not
/// keep a vault's paths. A store the user *explicitly* filled keeps working: a named workspace saved
/// while standing in a vault is a thing that was asked for by name, and silently dropping half of it
/// would be a worse surprise than remembering it. Favorites and saved searches are the same shape.
/// Recents needs no rule at all — it is a Spotlight query, and the measurement above is why it can
/// never see inside a vault.
public enum VaultPrivacy {
    /// Every mount point whose contents must stay out of implicit storage.
    ///
    /// Two sources, deliberately: the user's saved vaults that are attached right now, and **any**
    /// attached image that reports itself encrypted. The second is what covers an image unlocked in
    /// Disk Utility and then browsed here — Dirnex never saw a passphrase for it and has no row for
    /// it, and the rule is about the bytes rather than about the bookkeeping.
    public static func mountPoints(
        of vaults: SavedVaults,
        attached: [DiskImageMount.AttachedImage]
    ) -> [String] {
        var points: [String] = []
        for vault in vaults.vaults {
            guard let point = DiskImageMount.isMounted(imageAtPath: vault.imagePath, in: attached)
            else { continue }
            points.append(point)
        }
        for image in attached where image.isEncrypted {
            guard let point = image.mountPoint, !point.isEmpty else { continue }
            points.append(point)
        }
        var seen = Set<String>()
        return points.filter { seen.insert(VaultLocation.normalizedPath($0)).inserted }
    }

    /// Whether `path` is one of `mountPoints` or anything beneath it.
    ///
    /// Both sides go through ``VaultLocation/normalizedPath(_:)``, for the reason the mount
    /// comparison already does: `hdiutil` and the user spell the same place two ways, and a raw
    /// string comparison would answer "not in a vault" for a path that is.
    ///
    /// The boundary is a whole path component. `/Volumes/Vault` contains `/Volumes/Vault/taxes` and
    /// does **not** contain `/Volumes/VaultBackup`, which a bare `hasPrefix` would get wrong in the
    /// direction that matters least visibly — a directory silently dropped from session restore.
    public static func isInside(_ path: String, mountPoints: [String]) -> Bool {
        guard !mountPoints.isEmpty else { return false }
        let wanted = VaultLocation.normalizedPath(path)
        for point in mountPoints {
            let mount = VaultLocation.normalizedPath(point)
            guard !mount.isEmpty, mount != "/" else { continue }
            if wanted == mount || wanted.hasPrefix(mount + "/") { return true }
        }
        return false
    }

    /// Whether `path` is inside one of `mountPoints`. The `VFSPath` overload, which every caller in
    /// the app actually holds.
    ///
    /// A non-local backend is never inside a vault: an archive, a search result or an SFTP location
    /// is addressed by its own backend's rules, and a vault is a mounted volume the local backend
    /// browses. Answering on the raw string for those would compare a remote path against a local
    /// mount point, which can only ever produce a false positive.
    public static func isInside(_ path: VFSPath, mountPoints: [String]) -> Bool {
        guard path.backend == .local else { return false }
        return isInside(path.path, mountPoints: mountPoints)
    }
}
