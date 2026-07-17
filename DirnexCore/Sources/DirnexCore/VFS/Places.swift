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

        // Standard home subfolders, in the order Finder lists them.
        let subfolders: [(String, FavoritePlace.Kind)] = [
            ("Desktop", .desktop),
            ("Documents", .documents),
            ("Downloads", .downloads),
            ("Pictures", .pictures),
            ("Music", .music),
            ("Movies", .movies)
        ]
        for (component, kind) in subfolders {
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

    private static func isDirectory(_ path: String, _ fileManager: FileManager) -> Bool {
        var isDirectory: ObjCBool = false
        return fileManager.fileExists(atPath: path, isDirectory: &isDirectory) && isDirectory.boolValue
    }
}
