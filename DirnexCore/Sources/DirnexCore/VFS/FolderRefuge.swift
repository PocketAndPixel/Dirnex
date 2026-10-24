import Foundation

/// Where a pane goes when the folder it shows is deleted under it: the nearest folder above it that
/// still exists, which is what Total Commander and Finder do.
///
/// **A failed listing is not proof on its own.** FTP answers 550 for a folder that is gone and for
/// one the account may no longer open, and reads both as `notFound` (`FTPTransport`), while any
/// server can fail one request and answer the next. So the folder itself is asked first, and only
/// an answer that it is gone starts the walk. Anything else stops it: the folder answering, or an
/// error that says the server could not be asked rather than that nothing is there. A pane that
/// cannot be moved keeps the rows it has, as every refresh did before.
///
/// `stat` is the backend's, injected so the rule is tested without one. It is called once for the
/// folder and once per level above it, and never past the first folder found.
public enum FolderRefuge {
    /// The nearest folder above `path` that still exists, or `nil` when the pane should stay: the
    /// folder is still there, nothing above it could be confirmed, or the walk reached the root
    /// without finding one.
    public static func nearestExisting(
        above path: VFSPath,
        stat: (VFSPath) throws -> FileEntry
    ) -> VFSPath? {
        guard probe(path, stat) == .gone else { return nil }
        var candidate = path.parent
        while let folder = candidate {
            switch probe(folder, stat) {
            case .folder: return folder
            case .gone: candidate = folder.parent
            case .unknown: return nil
            }
        }
        return nil
    }

    private enum Answer {
        case folder
        case gone
        case unknown
    }

    /// What one `stat` says about `path`. A file where the folder was counts as gone, as
    /// `VFSError.meansPlaceIsGone` counts `notADirectory`: there is no folder there to show.
    private static func probe(_ path: VFSPath, _ stat: (VFSPath) throws -> FileEntry) -> Answer {
        do {
            return try stat(path).isDirectoryLike ? .folder : .gone
        } catch let error as VFSError where error.meansPlaceIsGone {
            return .gone
        } catch {
            return .unknown
        }
    }
}
