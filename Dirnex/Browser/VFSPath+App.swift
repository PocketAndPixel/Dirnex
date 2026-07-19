import DirnexCore
import Foundation

extension VFSPath {
    /// A file-system URL for a `.local` path. Only meaningful for the local backend
    /// (the only one wired up in M1); archive/SFTP paths get their own launch route
    /// when those backends land.
    var localURL: URL {
        URL(fileURLWithPath: path)
    }
}
