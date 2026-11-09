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
    /// The row is a file on this disk: its own `file://` URL, with nothing to fetch.
    case fileURL
    /// A folder on this disk: its own URL to every app, and a zip of it to any app the pointer enters
    /// with Shift held, since Gmail and the rest of Chromium take a file and fail on a folder
    /// (2026-11-08), while VLC takes the folder and a zip is no use to it (2026-11-09).
    case folderURL
    /// A file on a server: promised to Finder, and downloaded for any other app once the pointer
    /// is over it (`RemoteDragHandoff`).
    case download
    /// A folder on a server: promised to Finder, which is handed the tree F5's own queue job stages
    /// once the drop lands, with its bar and Stop in Dirnex (decision B, PLAN.md §M36 Slice 3). Any
    /// other app is handed the tree staged once the pointer is over it, and every app, Finder
    /// included, a zip of it when entered with Shift held, as a folder on this disk is.
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
        case .fileURL, .folderURL, .insideDirnexOnly: false
        }
    }

    /// Whether an app may be handed something the drag's handoff has to make once the pointer is over
    /// it (`RemoteDragHandoff`): a file brought down or extracted for an app other than Finder, a
    /// server's folder staged, or a folder zipped for an app entered with Shift held.
    ///
    /// A file on this disk is not: its own URL already serves every app.
    public var isHandedOff: Bool {
        switch self {
        case .download, .downloadFolder, .extract, .folderURL: true
        case .fileURL, .insideDirnexOnly: false
        }
    }

    /// Whether the row reaches an app as a zip of itself when the pointer enters it with Shift held,
    /// Finder included.
    ///
    /// Gmail and the rest of Chromium take a dropped file and fail on a folder (Gmail answers
    /// "Attachment failed"), while Finder and VLC take the folder, and no app says which it wants. So
    /// a folder goes as itself unless the user holds Shift as the pointer enters
    /// (``RemoteDragHandoff/Form``).
    public var zipsWithShift: Bool {
        switch self {
        case .folderURL, .downloadFolder: true
        case .download, .extract, .fileURL, .insideDirnexOnly: false
        }
    }

    /// The name another app is handed for a zip of the folder `folderName`: the folder's own name with
    /// `.zip` after it, as ⌥F5 names a pack of one folder.
    public static func zipName(forFolderNamed folderName: String) -> String {
        ArchivePacking.archiveFileName(baseName: folderName, format: .zip)
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
        if backend == .local { return entry.kind == .directory ? .folderURL : .fileURL }
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
