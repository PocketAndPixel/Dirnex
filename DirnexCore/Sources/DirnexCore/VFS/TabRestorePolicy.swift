import Foundation

/// What one persisted tab needs before it can list again, and whether that need can be met at all
/// (docs/LOCATION-SUPPORT.md ▸ "Session restore and workspaces drop remote tabs").
///
/// Session restore used to keep exactly the tabs it could list with no preparation whatsoever —
/// `backend == .local` and the directory still on disk — so quitting with four bucket tabs open
/// lost all four, and so did a browsed `.zip`. The saved connection survived in the sidebar; the
/// *place* did not. What separates the cases is not how remote they are but **what has to be true
/// first**, which is what this names: a directory that is still there, an archive file that is
/// still there, or a connection that has to be re-established.
///
/// It is a fact about the tab rather than about the machine, so it is pure and lives here; the
/// caller does the `stat` and the registering. Answering `nil` — "this cannot come back" — is a
/// real answer and not a failure, and the two virtual listings are why: a `.search` snapshot is
/// the answer to a question somebody asked once, and the merged `.trash` / `.icloud` containers are
/// gathered live from directories that are themselves the thing worth remembering. Restoring either
/// is a different feature with a different argument, and docs/LOCATION-SUPPORT.md marks both `n/a`
/// in the row this closes.
public enum TabRestoreRequirement: Sendable, Equatable {
    /// An on-disk directory: restorable while it is still a directory.
    case directoryOnDisk
    /// A browsed archive: restorable while the archive **file** at this on-disk path is still
    /// there. The tab's own path is the location *inside* it, so the file to check is the backend's,
    /// not the path's.
    case archiveOnDisk(path: String)
    /// A connected account: this endpoint has to be registered on the pane's backend before the
    /// listing can be asked for.
    case connection(ServerEndpoint)
}

/// Which persisted tabs can be brought back, and whether a restore may open a connection nobody
/// has just asked it to open.
public enum TabRestorePolicy {
    /// What `path` needs before it lists, given the endpoint stored beside it — or `nil` when the
    /// tab cannot be restored at all.
    ///
    /// **The endpoint has to *be* this path's backend**, and that check is the whole reason the
    /// pair is weighed together rather than the endpoint being trusted on sight. A persisted tab is
    /// JSON in a defaults domain: its path and its endpoint are two fields, and a store that has
    /// been hand-edited, half-migrated, or written by a build that recorded them from different
    /// places would connect to one server and then list a path belonging to another — a plausible
    /// listing under the wrong name, which is the quiet direction. ``ServerEndpoint/backendID`` is
    /// the join, and comparing it costs a string.
    ///
    /// A remote path with **no** endpoint answers `nil` rather than "restore it disconnected": the
    /// tab would come back pointing at a server with nothing that could ever reconnect it, which is
    /// a dead chip rather than a restored place. It is reachable — a session written by an older
    /// build carries the descriptor and no endpoint — so it is a case, not an impossibility.
    public static func requirement(
        for path: VFSPath,
        endpoint: ServerEndpoint?
    ) -> TabRestoreRequirement? {
        if path.backend == .local { return .directoryOnDisk }
        if let archivePath = path.backend.archivePath { return .archiveOnDisk(path: archivePath) }
        guard path.backend.isRemoteConnection else { return nil }
        guard let endpoint, endpoint.backendID == path.backend else { return nil }
        return .connection(endpoint)
    }
}

public extension RemoteRefreshPolicy {
    /// Whether the app may reach a server **nobody has just asked it to reach**.
    ///
    /// Settings ▸ Panels says it in so many words — *"Set it to 0 to never contact a server
    /// unasked"* — and until session restore could bring a remote tab back, the only thing that
    /// reached a server unasked was the poll, so the promise and the timer were the same rule. They
    /// are not any more: relaunching onto a restored bucket tab is a request the user never made
    /// *this* time, however true it is that they left the tab open. So the sentence gets a name and
    /// both readers ask it, rather than the poll owning it and the restore quietly making an
    /// exception to a promise printed in the Settings pane.
    ///
    /// It gates only the **unasked** half. Switching to a restored tab, clicking a crumb in its path
    /// bar, or re-entering it any other way is a gesture, and a gesture connects at any floor —
    /// otherwise "never contact a server unasked" would have become "never contact a server", which
    /// is not what the field says and not what anyone set it for.
    static func contactsServersUnasked(floor: TimeInterval) -> Bool {
        clampedFloor(floor) > 0
    }
}
