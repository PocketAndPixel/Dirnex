import DirnexCore
import Foundation

extension VFSPath {
    /// A file-system URL for a `.local` path. Only meaningful for the local backend
    /// (the only one wired up in M1); archive/SFTP paths get their own launch route
    /// when those backends land.
    var localURL: URL {
        URL(fileURLWithPath: path)
    }

    /// What to call this location when a sentence has to name it — the load-failure sheet's title,
    /// and anything else that would otherwise print a bare `lastComponent`.
    ///
    /// At a backend *root* `lastComponent` is `"/"`, which names nothing: opening a corrupt archive
    /// put «Can't open "/"» above a body that named `broken.zip` correctly, because the navigation
    /// target is the archive's inner root. So each backend that can be *rooted* supplies its own
    /// name — the archive's on-disk filename (for a nested mount, the extracted member's, which is
    /// the inner archive's own name), and the SFTP account as `user@host`, the same title the path
    /// bar's root crumb carries. Everything else keeps `lastComponent`, which is already right.
    var displayName: String {
        guard isRoot else { return lastComponent }
        if let archivePath = backend.archivePath {
            return (archivePath as NSString).lastPathComponent
        }
        if let location = backend.sftpLocation {
            return "\(location.username)@\(location.host)"
        }
        return lastComponent
    }
}
