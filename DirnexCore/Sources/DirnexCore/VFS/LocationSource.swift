import Foundation

/// Where a location's listing comes **from** — the kind of source a tab chip names with a glyph.
///
/// Not the sidebar place the pane is in (``SidebarPlaceLocator``), which is a different question
/// with a different answer: a folder in Downloads is *in* the Downloads favorite, while its source
/// is the Mac's own disk; and an archive, a share or a mounted disk image is a source the sidebar
/// has no place for at all. Each case is drawn with the glyph of the sidebar row that stands for
/// that kind of source, so the strip speaks the sidebar's vocabulary without being one more list
/// of places.
public enum LocationSource: Sendable, Hashable, CaseIterable {
    /// A folder on this Mac's own storage.
    case folder
    /// An external or removable drive, or a mounted disk image.
    case externalVolume
    /// A mounted share — SMB, and the AFP, NFS and WebDAV mounts that ride the same OS mounter.
    case networkVolume
    /// Inside an unlocked vault.
    case vault
    /// A `~/Library/CloudStorage` provider: Google Drive, Dropbox, OneDrive, Box.
    case cloudStorage
    /// iCloud Drive: its merged listing, or a folder inside any of its containers.
    case iCloudDrive
    case photos
    case archive
    case sftp
    case ftp
    /// An S3 bucket, or the account pane that lists the buckets.
    case s3
    /// A WebDAV account browsed through Dirnex's own backend — not a WebDAV share mounted by the
    /// OS, which is a ``networkVolume``.
    case webdav
    /// The merged Trash, or a folder inside one of the trash directories.
    case trash
    case recents
    /// A results listing: a search, a saved search or a tag.
    case search
}

public extension LocationSource {
    /// The source of `path`.
    ///
    /// A **local** path is placed by the territory it is inside, the most particular first: a trash
    /// directory, an unlocked vault, a cloud provider and iCloud Drive are all ordinary local folders
    /// that a sidebar row stands for by name; what is left is answered by the volume it lies on.
    ///
    /// Asks no file system anything on the way, so it is safe on the main thread with a share that
    /// has stopped answering. Every territory is a lexical test, the volume is found in the kernel's
    /// mount table (``MountTable``), and the one read it may make — `isInternalVolume` — is of a
    /// *local* volume's root, after a share has already been answered.
    ///
    /// `vaultMountPoints` is where each unlocked vault is mounted, which only `hdiutil` knows.
    static func of(
        _ path: VFSPath,
        mounts: [MountTableEntry],
        vaultMountPoints: [String],
        home: String = NSHomeDirectory(),
        isInternalVolume: (String) -> Bool = MountTable.isInternalVolume(at:)
    ) -> LocationSource {
        let backend = path.backend
        if backend == .local {
            return ofLocal(
                path,
                mounts: mounts,
                vaultMountPoints: vaultMountPoints,
                home: home,
                isInternalVolume: isInternalVolume
            )
        }
        if backend == .trash { return .trash }
        if backend == .icloud { return .iCloudDrive }
        if backend == .search { return path == SidebarPlaceLocator.recentsPath ? .recents : .search }
        if backend.isArchive { return .archive }
        if backend.isPhotos { return .photos }
        if backend.isSFTP { return .sftp }
        if backend.isFTP { return .ftp }
        if backend.isS3 || backend.isS3Account { return .s3 }
        if backend.isWebDAV { return .webdav }
        return .folder
    }

    private static func ofLocal(
        _ path: VFSPath,
        mounts: [MountTableEntry],
        vaultMountPoints: [String],
        home: String,
        isInternalVolume: (String) -> Bool
    ) -> LocationSource {
        // Ahead of the rest: a provider and a volume each keep a trash of their own, and a folder
        // opened from the Trash is somewhere you went *through* the Trash to reach.
        if TrashLocations.isInsideTrash(path, home: home) { return .trash }
        // Ahead of the volume: a vault is a disk image, which the mount table alone would call an
        // external drive.
        if VaultPrivacy.isInside(path, mountPoints: vaultMountPoints) { return .vault }
        if CloudStorageMounts.isInsideCloudStorage(path, home: home) { return .cloudStorage }
        // The whole of `Mobile Documents`, not only CloudDocs: a folder opened from an app's library
        // is iCloud Drive too, as its path bar says.
        if path.isSelfOrDescendant(of: ICloudDrive.mobileDocuments(home: home)) { return .iCloudDrive }

        guard let mount = MountTable.entry(containing: path.path, in: mounts) else { return .folder }
        if !mount.isLocal { return .networkVolume }
        // The external glyph is the Volumes section's, so it is only for a volume that section lists:
        // `/dev` and a simulator runtime are neither internal nor browsable, and are no drive anybody
        // plugged in.
        if mount.mountPoint == "/" || !mount.isBrowsable || isInternalVolume(mount.mountPoint) {
            return .folder
        }
        return .externalVolume
    }
}
