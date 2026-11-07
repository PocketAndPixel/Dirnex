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
    /// A file inside an archive this session can open: promised to Finder and extracted for any
    /// other app, the same two ways a server's file goes.
    case extract
    /// Nothing for another app. The row still drags to anywhere inside Dirnex.
    case insideDirnexOnly(Reason)

    /// Why a row offers another app nothing.
    public enum Reason: Sendable, Equatable {
        /// A folder that is not on this disk. A promise is one file, and a folder dragged into Finder
        /// waits on how Finder treats a promised folder (PLAN.md §M36, probe P1).
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
        case .download, .extract: true
        case .fileURL, .insideDirnexOnly: false
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
        case .directory: return .insideDirnexOnly(.folder)
        case .symlink, .other: return .insideDirnexOnly(.notAFile)
        }
    }
}
