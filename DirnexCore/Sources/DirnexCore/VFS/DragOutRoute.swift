import Foundation

/// What a dragged row offers an application other than Dirnex (PLAN.md §M36 Slice 2).
///
/// Every row drags *inside* Dirnex on its `PasteboardPayload`, whatever it is. This is the other
/// question, asked per row: what Finder, Mail or Teams is handed for it. It was answered in three
/// places in the app — `RemoteFilePromiseProvider.canPromise`, the drag's handoff controller and the
/// row's own pasteboard writer — each reading the backend and the kind for itself, and the archive
/// member that M36 adds would have been a fourth reading. So the answer is one function here, and the
/// app asks it.
public enum DragOutRoute: Sendable, Equatable {
    /// The row is a file or folder on this disk: its own `file://` URL, with nothing to fetch.
    case fileURL
    /// A file on a server: promised to Finder, and downloaded for any other app once the pointer
    /// is over it (`RemoteDragHandoff`).
    case download
    /// A folder on a server: promised to Finder, which is handed the tree F5's own queue job stages
    /// once the drop lands, with its bar and Stop in Dirnex (decision B, PLAN.md §M36 Slice 3). Mail
    /// takes the same promise (measured 2026-11-08); an app that refuses a promise is handed nothing
    /// for it, until probe P2's Teams and Chrome half says whether a file URL would do.
    case downloadFolder
    /// A file inside an archive this session can open: promised to Finder and extracted for any
    /// other app, the same two ways a server's file goes.
    case extract
    /// Nothing for another app. The row still drags to anywhere inside Dirnex.
    case insideDirnexOnly(Reason)

    /// Why a row offers another app nothing.
    public enum Reason: Sendable, Equatable {
        /// A folder inside an archive, or a bucket or share listed at an account's top level, which
        /// names a place rather than a folder F5 could copy out. A server's own folder is
        /// ``DragOutRoute/downloadFolder``.
        case folder
        /// A member of an encrypted archive whose passphrase this session does not hold. Asking for
        /// it would put a sheet on Dirnex's window, behind the app the drop went to, so the row is
        /// offered once the archive has been unlocked some other way (decision A, 2026-11-08).
        case lockedArchive
        /// A link or a special file on a server, or a row of a backend that is neither this disk,
        /// an archive nor a server. Nothing here has a file's bytes to hand over.
        case notAFile
    }

    /// Whether the row goes out as an `NSFilePromiseProvider`, rather than as a URL or not at all.
    public var isPromised: Bool {
        switch self {
        case .download, .downloadFolder, .extract: true
        case .fileURL, .insideDirnexOnly: false
        }
    }

    /// Whether an app that takes no promise is handed a file for the row once the pointer is over
    /// it, which is what the drag's handoff brings down (`RemoteDragHandoff`).
    ///
    /// A server's folder is promised and handed to nobody else. Finder named where it goes before
    /// anything is fetched, so the tree goes through the queue with a Stop; another app reads a file
    /// URL while the pointer is over it, and nothing says it takes a folder (probe P2).
    public var isHandedOff: Bool {
        switch self {
        case .download, .extract: true
        case .downloadFolder, .fileURL, .insideDirnexOnly: false
        }
    }

    /// The route for `entry`.
    ///
    /// `archiveIsLocked` answers for an archive's on-disk path: whether it needs a passphrase that
    /// this session does not hold. It is asked only of an archive member's own archive, and only
    /// for a file, so a drag of rows on this disk never reads a header.
    public static func route(
        for entry: FileEntry,
        archiveIsLocked: (String) -> Bool
    ) -> DragOutRoute {
        let backend = entry.path.backend
        if backend == .local { return .fileURL }
        if let archivePath = backend.archivePath {
            switch entry.kind {
            case .file:
                return archiveIsLocked(archivePath) ? .insideDirnexOnly(.lockedArchive) : .extract
            case .directory: return .insideDirnexOnly(.folder)
            case .symlink, .other: return .insideDirnexOnly(.notAFile)
            }
        }
        guard backend.isRemoteConnection else { return .insideDirnexOnly(.notAFile) }
        switch entry.kind {
        case .file: return .download
        case .directory:
            // An account pane lists buckets and a server pane lists shares: places, which the
            // queue's copy cannot walk from there.
            if backend.isS3Account || backend.isSMBServer { return .insideDirnexOnly(.folder) }
            return .downloadFolder
        case .symlink, .other: return .insideDirnexOnly(.notAFile)
        }
    }
}
