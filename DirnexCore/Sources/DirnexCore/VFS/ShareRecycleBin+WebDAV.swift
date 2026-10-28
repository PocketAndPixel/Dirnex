import Foundation

/// The share recycle bin a WebDAV delete may land in (PLAN.md §M32, after Slice 6).
///
/// A DELETE over WebDAV is permanent as far as the protocol goes, and the sheet says so. On the NAS
/// it is not: DSM's WebDAV server lists the account's shared folders at `/`, and a folder deleted
/// from `/home` landed in `/home/#recycle` with its own name (measured 2026-10-23 and 2026-10-24,
/// every live run's folders). So the sheet promising destruction is wrong there in the safe
/// direction, as it was over SMB (``ShareRecycleBin``), and this names the one path whose existence
/// would make the softer sentence true.
///
/// **Pure**: it names the bin and does not look. Whether the folder is there is one `Depth: 0`
/// request, which the app makes before the sheet, and which answers *may*: DSM leaves the folder
/// behind when the setting is switched off.
public extension ShareRecycleBin {
    /// The bin that would catch a DELETE of **every** one of `paths`, as a path on their WebDAV
    /// backend, or `nil` when there is none to ask about.
    ///
    /// The share is the **first segment of the server path**, the location's root included,
    /// because that is where DSM keeps one bin per shared folder. `nil`:
    ///
    /// - for a path that is not on a WebDAV backend;
    /// - for a path already in a bin, or the bin itself, where a delete really is permanent
    ///   (``isBinOrInside(_:)``, measured over SMB);
    /// - for the share itself, or the account root: there is no bin above a share, and the server
    ///   refuses to delete one anyway;
    /// - when the bin sits above the location's root (a root of `/home/projects` cannot see
    ///   `/home/#recycle`), since the backend can only ask about what is inside its root;
    /// - for a set that would land in more than one bin, or on more than one account.
    ///
    /// Nextcloud keeps deleted files in a trash of its own, outside the files tree
    /// (`/remote.php/dav/trashbin/<user>/trash`, measured), and is not covered: its root is several
    /// segments deep, so the bin this rule would name, `/remote.php/#recycle`, is above it, and the
    /// answer is `nil`.
    static func webDAVBin(catching paths: [VFSPath]) -> VFSPath? {
        var governing: VFSPath?
        for path in paths {
            guard let location = path.backend.webDAVLocation,
                  let bin = webDAVBin(catching: path, on: location),
                  governing == nil || governing == bin
            else { return nil }
            governing = bin
        }
        return governing
    }

    private static func webDAVBin(catching path: VFSPath, on location: WebDAVLocation) -> VFSPath? {
        let serverPath = location.serverPath(forBackendPath: path.path)
        let components = serverPath.split(separator: "/", omittingEmptySubsequences: true)
        guard components.count >= 2,
              !components.contains(where: { $0 == directoryName }),
              let binPath = location.backendPath(forServerPath: "/\(components[0])/\(directoryName)")
        else { return nil }
        return VFSPath(backend: path.backend, path: binPath)
    }
}
