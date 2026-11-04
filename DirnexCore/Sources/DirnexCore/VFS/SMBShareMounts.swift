import Foundation

/// Where each share of one SMB server is mounted right now, so a tab on that server's list can write
/// down a place inside a share and find it again after a relaunch (PLAN.md §M35).
///
/// A tab spells everything it restores (open tree folders, the cursor, the marks) as a path relative
/// to its root. On a server's list the root is the list, and the rows beneath an expanded share are
/// **local** paths under that share's mount point, which are not under the root at all, so they were
/// dropped on the way down: a tab left three levels into `media` came back with `media` open and the
/// cursor on the first row (reported 2026-11-04). Spelled through the share instead, as
/// `media/Movies/Crime.mkv`, they survive. On the way back the share is not mounted until its row
/// is, and its mount point may not be the same one, so a path under a share resolves only against the
/// mount that share has now.
public struct SMBShareMounts: Sendable, Equatable {
    /// Each mounted share's name, as its row is named, to its mount point.
    public let mountPoints: [String: String]

    public init(_ mountPoints: [String: String]) {
        self.mountPoints = mountPoints
    }

    /// A local path under one of these mounts as `<share>/<rest>`, or the share's name for the mount
    /// point itself, or `nil` when the path is under none of them.
    ///
    /// The longest mount point that holds the path wins, and a mount point holds only what is under
    /// it by whole components, so `/Volumes/media-1/x` is not under `/Volumes/media`.
    public func serverRelativePath(ofLocal path: String) -> String? {
        let holding = mountPoints.filter { _, mountPoint in
            path == mountPoint || path.hasPrefix(
                mountPoint.hasSuffix("/") ? mountPoint : mountPoint + "/"
            )
        }
        guard let (share, mountPoint) = holding.max(by: { $0.value.count < $1.value.count }) else {
            return nil
        }
        let rest = path.dropFirst(mountPoint.count).drop { $0 == "/" }
        return rest.isEmpty ? share : "\(share)/\(rest)"
    }

    /// What a stored path on the server's list names now.
    public enum Resolution: Sendable, Equatable {
        /// The share's own row on the list: a path of one component.
        case shareRow(String)
        /// A place inside a mounted share, at its mount point.
        case local(VFSPath)
        /// A place inside a share that is not mounted yet, so it cannot be named until it is.
        case awaitingMount(share: String)
    }

    /// Resolve a path written by ``serverRelativePath(ofLocal:)``, or `nil` for an empty one.
    public func resolve(_ relative: String) -> Resolution? {
        let components = relative.split(separator: "/").map(String.init)
        guard let share = components.first else { return nil }
        guard components.count > 1 else { return .shareRow(share) }
        guard let mountPoint = mountPoints[share] else { return .awaitingMount(share: share) }
        return .local(components.dropFirst().reduce(VFSPath.local(mountPoint)) { $0.appending($1) })
    }
}
