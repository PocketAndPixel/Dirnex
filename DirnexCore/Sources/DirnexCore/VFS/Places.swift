import Foundation

/// A well-known user folder shown in the sidebar's **Favorites** section — the macOS
/// answer to Total Commander's drive buttons for the common jump targets (PLAN.md §M1
/// "Volumes/places strip (replaces TC's drive letters)").
///
/// Only folders that actually exist are surfaced, so a machine without a `~/Movies`
/// never shows a dead row.
public struct FavoritePlace: Sendable, Hashable, Identifiable {
    /// Which standard folder this is — kept as semantic metadata so the UI (or a later
    /// palette action) can treat, say, Downloads specially, independent of its name.
    public enum Kind: String, Sendable, Hashable, CaseIterable {
        case home, desktop, documents, downloads, applications, movies, music, pictures
    }

    public let name: String
    public let path: VFSPath
    public let kind: Kind

    public init(name: String, path: VFSPath, kind: Kind) {
        self.name = name
        self.path = path
        self.kind = kind
    }

    public var id: VFSPath { path }
}

/// A mounted, browsable volume shown in the sidebar's **Volumes** section — the local
/// filesystem's drives, external disks, and removable media.
///
/// This is a plain value snapshot of the mount table at enumeration time; the UI
/// re-enumerates on mount/unmount notifications rather than mutating these in place.
public struct MountedVolume: Sendable, Hashable, Identifiable {
    public let name: String
    public let path: VFSPath
    /// The volume is the root filesystem (`/`) — pinned to the top and never ejectable.
    public let isRoot: Bool
    /// Removable media (USB stick, SD card) — carries an eject affordance.
    public let isRemovable: Bool
    /// The device can be ejected (optical media, disk images, external drives).
    public let isEjectable: Bool
    /// Built-in, non-removable storage.
    public let isInternal: Bool
    public let isReadOnly: Bool
    /// Total/available bytes, when the volume reports them (network shares may not).
    public let totalCapacity: Int64?
    public let availableCapacity: Int64?

    public init(
        name: String,
        path: VFSPath,
        isRoot: Bool,
        isRemovable: Bool,
        isEjectable: Bool,
        isInternal: Bool,
        isReadOnly: Bool,
        totalCapacity: Int64?,
        availableCapacity: Int64?
    ) {
        self.name = name
        self.path = path
        self.isRoot = isRoot
        self.isRemovable = isRemovable
        self.isEjectable = isEjectable
        self.isInternal = isInternal
        self.isReadOnly = isReadOnly
        self.totalCapacity = totalCapacity
        self.availableCapacity = availableCapacity
    }

    public var id: VFSPath { path }

    /// Whether the sidebar offers an eject button. Finder shows one for anything that isn't
    /// built-in storage: removable media (USB stick, SD card), ejectable media (optical, disk
    /// images), and plain external drives — which often report neither `isEjectable` nor
    /// `isRemovable`, only `isInternal == false`, so that alone must qualify. Never the root
    /// filesystem (you can't eject the disk you booted from).
    public var canEject: Bool { !isRoot && (isEjectable || isRemovable || !isInternal) }

    /// The SF Symbol standing in for this volume in the sidebar, mirroring Finder's Locations
    /// section: built-in storage reads as an internal drive, everything else — USB sticks,
    /// external SSDs, mounted disk images — as an external one. Deliberately only that split:
    /// the mount-table flags can't tell an optical disc from a read-only disk image (both are
    /// ejectable + read-only + non-removable), so guessing a third glyph would misfire.
    public var symbolName: String {
        isRoot || isInternal ? "internaldrive" : "externaldrive"
    }
}

/// Enumerates the two kinds of sidebar destinations — standard user folders and
/// mounted volumes — from Foundation only (no AppKit), so the whole thing is unit
/// testable headless and the app layer just renders and navigates the results.
public enum SidebarLocations {
    /// Standard user folders that exist right now, in a stable, Finder-like order.
    /// `home` is always first; the rest are included only when present on disk.
    public static func favorites(
        home: String = NSHomeDirectory(),
        fileManager: FileManager = .default
    ) -> [FavoritePlace] {
        let homePath = VFSPath.local(home)
        var places = [FavoritePlace(name: "Home", path: homePath, kind: .home)]

        for (component, kind) in homeSubfolders {
            let path = homePath.appending(component)
            if isDirectory(path.path, fileManager) {
                places.append(FavoritePlace(name: component, path: path, kind: kind))
            }
        }

        // `/Applications` is a system-level favorite, not under home.
        let applications = VFSPath.local("/Applications")
        if isDirectory(applications.path, fileManager) {
            places.append(
                FavoritePlace(name: "Applications", path: applications, kind: .applications)
            )
        }

        return places
    }

    /// The user's iCloud Drive container, when iCloud Drive is enabled and its folder exists on
    /// disk: `~/Library/Mobile Documents/com~apple~CloudDocs` (PLAN.md §M8 "iCloud Drive row").
    ///
    /// Returns `nil` when the container is absent — a Mac with iCloud Drive turned off has none — so
    /// the sidebar shows no dead row, the same "only what exists" rule `favorites()` follows. Note
    /// that only the `com~apple~CloudDocs` leaf is reachable without Full Disk Access; its parent
    /// `~/Library/Mobile Documents` is TCC-gated, so this must probe the leaf directly rather than
    /// enumerate the parent (probed 2026-07-20).
    ///
    /// The path browses through the local backend like any other folder. Because that backend lists
    /// via a pure `stat` and never opens a file, an evicted item is **not** downloaded merely by
    /// being listed. It is also not a `.<name>.icloud` stub: re-probed 2026-07-21 with `brctl
    /// evict`, a modern macOS placeholder keeps its real name and size and is marked `SF_DATALESS`,
    /// which the listing carries as `FileEntry.isDataless` (PLAN.md §M9).
    ///
    /// This is only *half* of iCloud Drive. Finder merges this container with every iCloud-enabled
    /// app's own document folder, which live beside it rather than inside it — see `ICloudDrive`.
    public static func iCloudDrive(
        home: String = NSHomeDirectory(),
        fileManager: FileManager = .default
    ) -> VFSPath? {
        let path = VFSPath.local(home)
            .appending("Library")
            .appending("Mobile Documents")
            .appending("com~apple~CloudDocs")
        return isDirectory(path.path, fileManager) ? path : nil
    }

    /// Every trash directory that exists right now, home first, then one per non-boot volume that
    /// has one (PLAN.md §M8 "Trash is also per-volume … so a single row is a lie on a multi-drive
    /// setup"). The sidebar's one Trash row merges these into a single listing.
    ///
    /// The boot volume is skipped deliberately rather than overlooked: its user trash *is*
    /// `~/.Trash`, already first in the list, and its `/.Trashes/<uid>` is either absent or somebody
    /// else's. Probed 2026-07-21 — `FileManager` resolves the trash "appropriate for" `/`, for
    /// `/System/Volumes/Data` and for the `/Volumes/Macintosh HD` symlink all to `~/.Trash`, so
    /// treating the root volume like the others would list the home trash two or three times over.
    ///
    /// A volume with nothing trashed on it has no `.Trashes/<uid>` yet and contributes nothing,
    /// which is the same "only what exists" rule `favorites()` and `iCloudDrive()` follow. Note that
    /// existence is all this checks: `~/.Trash` exists on every Mac but reads back a permission
    /// error without Full Disk Access, so a caller still has to handle a denied listing.
    public static func trashDirectories(
        home: String = NSHomeDirectory(),
        volumes: [MountedVolume],
        uid: uid_t = getuid(),
        fileManager: FileManager = .default
    ) -> [VFSPath] {
        var directories: [VFSPath] = []
        let homeTrash = TrashLocations.homeTrash(home: home)
        if isDirectory(homeTrash.path, fileManager) { directories.append(homeTrash) }

        // iCloud Drive's own trash, which is neither the home one nor a volume's — deleting inside
        // iCloud Drive lands here, and only here (PLAN.md §M9, probed).
        let iCloudTrash = TrashLocations.iCloudTrash(home: home)
        if isDirectory(iCloudTrash.path, fileManager) { directories.append(iCloudTrash) }

        // Every `~/Library/CloudStorage` provider mount keeps its own trash too, one per *account*
        // — deleting inside Google Drive lands there and nowhere else, so without these a Drive
        // delete is a file the user can see in Finder's Trash and not in ours (probed 2026-07-22,
        // the same report that turned up the iCloud trash). `named` rather than `mounts` on purpose:
        // it does not look inside a mount, whose `readdir` can reach the network.
        for mount in CloudStorageMounts.named(home: home, fileManager: fileManager) {
            let trash = TrashLocations.cloudStorageTrash(inMountAt: mount.path)
            if isDirectory(trash.path, fileManager) { directories.append(trash) }
        }

        for volume in volumes where !volume.isRoot {
            let trash = TrashLocations.volumeTrash(onVolumeAt: volume.path, uid: uid)
            if isDirectory(trash.path, fileManager) { directories.append(trash) }
        }
        return directories
    }

    /// Mounted, browsable volumes, root filesystem first, then the rest by name.
    /// Non-browsable volumes (e.g. the hidden Recovery/VM partitions) are excluded.
    public static func volumes(fileManager: FileManager = .default) -> [MountedVolume] {
        let keys: Set<URLResourceKey> = [
            .volumeNameKey,
            .volumeIsBrowsableKey,
            .volumeIsRemovableKey,
            .volumeIsEjectableKey,
            .volumeIsInternalKey,
            .volumeIsReadOnlyKey,
            .volumeIsRootFileSystemKey,
            .volumeTotalCapacityKey,
            .volumeAvailableCapacityKey
        ]
        guard let urls = fileManager.mountedVolumeURLs(
            includingResourceValuesForKeys: Array(keys),
            options: [.skipHiddenVolumes]
        ) else { return [] }

        let volumes = urls.compactMap { url -> MountedVolume? in
            guard let values = try? url.resourceValues(forKeys: keys),
                  values.volumeIsBrowsable ?? true else { return nil }
            let isRoot = values.volumeIsRootFileSystem ?? (url.path == "/")
            return MountedVolume(
                name: values.volumeName ?? url.lastPathComponent,
                path: VFSPath.local(url.path),
                isRoot: isRoot,
                isRemovable: values.volumeIsRemovable ?? false,
                isEjectable: values.volumeIsEjectable ?? false,
                isInternal: values.volumeIsInternal ?? false,
                isReadOnly: values.volumeIsReadOnly ?? false,
                totalCapacity: values.volumeTotalCapacity.map(Int64.init),
                availableCapacity: values.volumeAvailableCapacity.map(Int64.init)
            )
        }

        return volumes.sorted { lhs, rhs in
            if lhs.isRoot != rhs.isRoot { return lhs.isRoot }
            return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
        }
    }

    /// The standard home subfolders, in the order Finder lists them. One table, read by both
    /// `favorites()` and `standardKind(for:)`, so an entry can never be enumerated under a kind
    /// the classifier then fails to recognize.
    private static let homeSubfolders: [(String, FavoritePlace.Kind)] = [
        ("Desktop", .desktop),
        ("Documents", .documents),
        ("Downloads", .downloads),
        ("Pictures", .pictures),
        ("Music", .music),
        ("Movies", .movies)
    ]

    /// The standard-folder identity of `path`, or `nil` for anywhere else.
    ///
    /// Needed once the sidebar's Favorites section is a user-owned pin list (PLAN.md §M8): rows
    /// then arrive as bare paths rather than pre-tagged `FavoritePlace`s, and without this every
    /// one of them would fall back to the generic folder icon instead of its own symbol.
    ///
    /// Deliberately a pure path mapping that touches no disk, unlike `favorites()`. Two things
    /// follow, both wanted: a pinned folder that has since been deleted still renders as
    /// Documents rather than degrading the moment it goes missing, and a user who removes the
    /// seeded Downloads row and later drags it back in gets its symbol back rather than being
    /// permanently demoted to a plain folder.
    public static func standardKind(
        for path: VFSPath,
        home: String = NSHomeDirectory()
    ) -> FavoritePlace.Kind? {
        guard path.backend == .local else { return nil }
        let homePath = VFSPath.local(home)
        if path == homePath { return .home }
        if path == VFSPath.local("/Applications") { return .applications }
        guard path.parent == homePath else { return nil }
        return homeSubfolders.first { $0.0 == path.lastComponent }?.1
    }

    private static func isDirectory(_ path: String, _ fileManager: FileManager) -> Bool {
        var isDirectory: ObjCBool = false
        return fileManager.fileExists(atPath: path, isDirectory: &isDirectory) && isDirectory.boolValue
    }
}
