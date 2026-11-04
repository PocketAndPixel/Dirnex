import AppKit
import DirnexCore

/// An SMB server's shares, as a pane (PLAN.md §M35): the pane whose rows are shares, the way an S3
/// account's are buckets (`PanelViewController+S3Account`).
///
/// Four gestures, and each one crosses between backends rather than walking a path:
///
/// - *Connect with no share* lists the server once, to learn whether the account is let in, then
///   registers an `SMBServerBackend` and lands the pane on its root. NetFS's own share picker is
///   never shown.
/// - *Return on a share* mounts it through `SMBMounter`, with no UI and the server's own account, and
///   goes into the mount point, a `.local` path like any volume.
/// - *`..` at that mount point* goes back to the list, with the cursor on the share.
/// - *→ on a share in a tree* mounts it too, and lists the mount point beneath the row.
extension PanelViewController {
    // MARK: - Connecting

    /// List `request`'s server and, if it answers, stand on its shares.
    ///
    /// The password is filed under the **server's** Keychain key (`user@host`), which is a share's
    /// key without the trailing `/share`, so the two never collide. `focus` is the share to land the
    /// cursor on when this connect is a walk up out of one.
    func connectSMBServer(
        _ request: SMBConnectRequest,
        focus: VFSPath? = nil
    ) async -> ConnectServerPrompt.Attempt {
        guard let composite = backend as? CompositeBackend else {
            return .failed(Self.genericConnectError)
        }
        let server = request.location.server
        let password = server.username == nil ? nil : request.password
        let enumerator = SMBShareEnumerator(server: server, password: password)
        let token = loadToken
        if let activityName = request.activityName { SidebarRowActivity.shared.begin(activityName) }
        defer {
            if let activityName = request.activityName { SidebarRowActivity.shared.end(activityName) }
        }

        let result = await BlockingWork.run { () -> Result<[SMBShare], Error> in
            Result { try enumerator.shares() }
        }
        guard token == loadToken else { return .succeeded } // the pane moved on while we listed

        switch result {
        case .success:
            if server.username != nil, let password {
                SecretKeychain.store(password: password, for: server)
            }
            composite.connectSMBServer(server: server, password: password)
            if let saveName = request.saveName {
                saveServer(name: saveName, endpoint: .smb(server))
            }
            navigate(
                to: VFSPath(backend: .smbServer(server), path: "/"),
                focus: focus,
                inNewTab: request.inNewTab
            )
            return .succeeded
        case let .failure(error):
            let status = (error as? SMBShareListingError)?.status ?? Int32(EIO)
            return .failed(
                SMBMountError(status: status, location: server).errorDescription
                    ?? Self.genericConnectError
            )
        }
    }

    // MARK: - Entering a share

    /// The share Return would mount for this row, or `nil` when the row opens some other way. Asked of
    /// the **row**: in a tree, the folders under an expanded share are local paths and open as
    /// folders.
    func smbShareToEnter(for entry: FileEntry) -> VFSPath? {
        entry.path.isSMBShareRow ? entry.path : nil
    }

    /// Mount the share row at `path` and go into it.
    ///
    /// `inNewTab` and `focusing` are for ⌘Return in the other pane, which asks this pane to open the
    /// share in a new tab and leave the focus where it was, as a bucket row does.
    func enterSMBShare(at path: VFSPath, inNewTab: Bool = false, focusing: Bool = true) {
        guard let request = smbShareMountRequest(for: path) else {
            presentOperationFailure(
                message: connectFailureTitle(path.backend.smbServer?.host ?? path.lastComponent),
                detail: Self.genericConnectError
            )
            return
        }
        var landing = request
        landing.inNewTab = inNewTab
        runConnect(host: request.location.host, focusing: focusing) { [self] in
            await mountSMB(landing)
        }
    }

    /// The mount one share row stands for, with the account and password of the connection that
    /// listed it. `nil` when that connection is gone. The password is not filed again under the
    /// share's own key: the server's item already holds it.
    private func smbShareMountRequest(for path: VFSPath) -> SMBConnectRequest? {
        guard path.isSMBShareRow,
              let composite = backend as? CompositeBackend,
              let connection = composite.smbServerConnection(for: path.backend)
        else { return nil }
        var request = SMBConnectRequest(
            location: connection.backend.server.share(named: path.lastComponent),
            password: connection.password,
            saveName: nil,
            activityName: nil
        )
        request.filesPassword = false
        return request
    }

    // MARK: - Expanding a share in a tree

    /// The rows beneath an expanded **share row** in a tree: the share's own root, once mounted.
    ///
    /// The children are the mount point's, on `.local`, so everything below them is an ordinary
    /// folder and needs nothing more from here. A share already mounted is found and reused without
    /// asking the server (`SMBMounter.mount`), so a tree refresh costs no session. A failure names
    /// the share on the status line and leaves the reasons to Return, which has an alert for them.
    func smbShareChildren(at path: VFSPath) async -> [FileEntry]? {
        guard let request = smbShareMountRequest(for: path) else {
            reportShareExpansionFailure(path.lastComponent)
            return nil
        }
        let mountPoint: URL
        do {
            mountPoint = try await SMBMounter.shared.mount(
                request.location,
                username: request.location.username,
                password: request.password
            )
        } catch {
            reportShareExpansionFailure(path.lastComponent)
            return nil
        }
        guard let listing = try? await DirectoryLoader.list(backend, at: .local(mountPoint.path)) else {
            reportShareExpansionFailure(path.lastComponent)
            return nil
        }
        return listing.entries
    }

    /// The bucket expansion's sentence, word for word and with its comment, so the two are one key.
    private func reportShareExpansionFailure(_ share: String) {
        showTransientStatus(String(
            localized: "Couldn’t open “\(share)”",
            comment: "Failure title; %@ is the name of the item that couldn’t be opened."
        ))
    }

    // MARK: - Leaving a share

    /// Whether this pane stands at the root of a share Dirnex mounted, where `..` goes up to the
    /// server's shares rather than to `/Volumes` (PLAN.md §M35).
    var leavesShareForItsServer: Bool {
        panel.path.backend == .local && SMBMounter.shared.share(mountedAt: panel.path.path) != nil
    }

    /// Go up from a share's root to its server's list, with the cursor on the share.
    ///
    /// A server already connected in this window is listed again and nothing more. Otherwise it is
    /// connected with the password the share was mounted with, read back from the share's Keychain
    /// item, or the server's when the share was reached from the list.
    func leaveShareForItsServer() {
        guard let share = SMBMounter.shared.share(mountedAt: panel.path.path),
              let shareName = share.share
        else { return }
        let server = share.server
        let focus = VFSPath(backend: .smbServer(server), path: "/\(shareName)")
        if let composite = backend as? CompositeBackend, composite.isConnected(.smbServer(server)) {
            navigate(
                to: VFSPath(backend: .smbServer(server), path: "/"),
                focus: focus,
                inNewTab: false
            )
            return
        }
        var password: String?
        if server.username != nil {
            password = SecretKeychain.password(for: share) ?? SecretKeychain.password(for: server)
            guard password != nil else {
                presentOperationFailure(
                    message: connectFailureTitle(server.host),
                    detail: Self.genericConnectError
                )
                return
            }
        }
        let request = SMBConnectRequest(
            location: server,
            password: password,
            saveName: nil,
            activityName: nil
        )
        runConnect(host: server.host) { [self] in await connectSMBServer(request, focus: focus) }
    }

    // MARK: - Restoring a tree inside a share

    /// The share a stored tree folder is inside, when that share is not mounted yet and the folder
    /// has to wait for it, or `nil` when it can be named now.
    func shareAwaitingMount(_ relative: String, under root: VFSPath) -> String? {
        guard root.isRoot, let server = root.backend.smbServer,
              case let .awaitingMount(share)? = SMBMounter.shared.mounts(of: server).resolve(
                  relative
              )
        else { return nil }
        return share
    }

    /// Open the restored folders that were waiting inside `shareRow`, now that its expansion has
    /// mounted it, at the mount point it has this time. Ones that still cannot be named (the share
    /// did not mount, or the tab is no longer the one in front) are given up, each closing its part of
    /// the restore window so the cursor and marks still pending are dropped when nothing else is
    /// coming (`finishRestoreTreeLoad`).
    func restoreExpansionsInsideShare(_ shareRow: VFSPath, inTab index: Int) {
        guard tabs.indices.contains(index) else { return }
        let waiting = tabs[index].pendingShareExpansions.removeValue(forKey: shareRow.lastComponent)
        guard let waiting, !waiting.isEmpty else { return }
        for relative in waiting {
            let path = resolveRootRelative(relative, under: panel.path)
            guard index == activeTabIndex, path.backend == .local else {
                finishRestoreTreeLoad(inTab: index)
                continue
            }
            panel.expand(path)
            loadTreeChild(path, duringRestore: true)
        }
        renderTreeChange()
    }

    // MARK: - Reading a refusal

    /// What the server's list says about a share that answered `ENOENT`: listed to this account, not
    /// listed, or no list to be had (PLAN.md §M35). One more session, spent only on a failure.
    func smbShareAbsence(of location: SMBLocation, password: String?) async -> SMBShareAbsence {
        guard let share = location.share else { return .unknown }
        let enumerator = SMBShareEnumerator(server: location.server, password: password)
        let listing = await BlockingWork.run { try? enumerator.shares() }
        return SMBShareAbsence.reading(share: share, listing: listing)
    }
}
