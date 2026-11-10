import Foundation

/// What brings back a pinned folder whose network share is not mounted right now.
///
/// A share rides the OS mounter, so a pin inside one is an ordinary local path such as
/// `/Volumes/media/TV`, and the pin outlives the mount: Dirnex unmounts what it mounted on quit, so
/// the next launch found the folder missing and offered to remove the pin (reported 2026-11-10).
/// The folder was fine. What was missing was the mount, and picking the pin is a request to reach it.
///
/// Pure, like ``TabRestorePolicy``: the caller reads the mount table and does the mounting.
public enum PinnedShare {
    private static let volumesDirectory = "Volumes"

    /// The name of the volume `path` needs, when `path` is under `/Volumes/<name>` and nothing is
    /// mounted there, or `nil` when no mount would help.
    ///
    /// `nil` for a volume that **is** mounted, since a folder missing from a mounted volume really
    /// is gone. `/Volumes/Macintosh HD` is why `isSymlink` is asked: it is a link to `/`, so it has
    /// no mount table entry of its own, and a deleted folder reached through it would otherwise read
    /// as a share called "Macintosh HD".
    public static func unmountedVolume(
        of path: VFSPath,
        mounted: [MountTableEntry],
        isSymlink: (String) -> Bool
    ) -> String? {
        guard path.backend == .local else { return nil }
        let components = path.path.split(separator: "/")
        guard components.count >= 2, components[0] == volumesDirectory else { return nil }
        let name = String(components[1])
        let mountPoint = "/\(volumesDirectory)/\(name)"
        guard !mounted.contains(where: { $0.mountPoint == mountPoint }), !isSymlink(mountPoint) else {
            return nil
        }
        return name
    }

    /// The shares that could bring `entry` back, best first.
    ///
    /// A pin that recorded its share has one answer and it is not second-guessed. A pin made before
    /// pins recorded one (``FavoriteEntry/endpoint``) can only be matched by the volume's name, which
    /// macOS takes from the share's: a saved server naming that share first, then every saved server
    /// asked for a share of that name, in the sidebar's order. A listing cannot narrow these, because
    /// a server names a share even to an account it refuses (docs/NOTES.md ▸ SMB), so each one is
    /// tried until one mounts.
    public static func candidates(
        for entry: FavoriteEntry,
        volume: String,
        saved: [ServerConnection]
    ) -> [SMBLocation] {
        if let share = entry.serverEndpoint?.smbShare { return [share] }
        let locations = saved.compactMap { connection -> SMBLocation? in
            guard case let .smb(location) = connection.endpoint else { return nil }
            return location
        }
        let named = locations.filter { $0.share?.caseInsensitiveCompare(volume) == .orderedSame }
        let onServers = locations.filter { $0.share == nil }.map { $0.share(named: volume) }
        var seen = Set<SMBLocation>()
        return (named + onServers).filter { seen.insert($0).inserted }
    }

    /// `path`, on the volume mounted at `mountPoint`. The two can differ: macOS mounts a share at
    /// `/Volumes/media-1` when `/Volumes/media` is taken, and the pin keeps the spelling it was made
    /// with.
    public static func path(_ path: VFSPath, onMountPoint mountPoint: String) -> VFSPath {
        path.path.split(separator: "/").dropFirst(2).reduce(.local(mountPoint)) { folder, component in
            folder.appending(String(component))
        }
    }
}

public extension ServerEndpoint {
    /// The share this endpoint names, or `nil` for anything else, an SMB server with no share
    /// included.
    var smbShare: SMBLocation? {
        guard case let .smb(location) = self, location.share != nil else { return nil }
        return location
    }
}

public extension Favorites {
    /// Write down which share the pin at `path` is on, once mounting it has shown which one that is.
    /// A pin that already records where to reconnect keeps what it has. Returns whether anything
    /// changed, so a caller can skip a needless write.
    @discardableResult
    mutating func recordShare(_ share: SMBLocation, for path: VFSPath) -> Bool {
        guard let entry = entries.first(where: { $0.path == path }), entry.endpoint == nil else {
            return false
        }
        replace(FavoriteEntry(name: entry.name, path: path, endpoint: .smb(share)))
        return true
    }
}
