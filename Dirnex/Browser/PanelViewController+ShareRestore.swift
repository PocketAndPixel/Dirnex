import DirnexCore
import Foundation

/// A restored tab inside an SMB share that is not mounted (`TabRestoreRequirement.shareMount`).
///
/// Dirnex unmounts what it mounted on quit, so a tab left inside a share came back to a folder that
/// was not there and was dropped. It now comes back, and the navigation that first wants it mounts
/// the share, by the rules a restored server tab reconnects by (`PanelViewController+Reconnect`):
/// the launch activation mounts unless Settings ▸ Panels says never to contact a server unasked, and
/// any gesture mounts. The seam is `navigate` for the reason given there.
extension PanelViewController {
    /// What a navigation to `path` owes the share the active tab is waiting on.
    ///
    /// Only a tab that has not listed yet is asked: once it has, its trail is an ordinary one, and a
    /// walk back to a folder on an unmounted share is skipped the way a deleted folder is. `floor`
    /// is a defaulted parameter for the reason ``reconnectVerdict(to:unasked:floor:)`` gives.
    func shareMountVerdict(
        to path: VFSPath,
        unasked: Bool,
        floor: TimeInterval = AppPreferences.shared.remoteRefreshFloor
    ) -> ReconnectVerdict {
        let tab = tabs[activeTabIndex]
        guard !tab.hasLoaded, let awaited = tab.awaitedShare, awaited.holds(path),
              PinnedShare.unmountedVolume(
                  of: path,
                  mounted: MountTable.current(),
                  isSymlink: Self.isSymlink
              ) != nil
        else { return .listNow }
        guard !unasked || RemoteRefreshPolicy.contactsServersUnasked(floor: floor) else {
            return .standDown(.serversNotContactedUnasked)
        }
        let share = awaited.share
        guard share.username == nil || Self.storedPassword(forShare: share) != nil else {
            return .standDown(.credentialMissing)
        }
        return .connect(.smb(share))
    }

    /// Mount the active tab's share before `path` is listed, when it is waiting on one. Returns
    /// whether it took the navigation over; the mount navigates again once it is done.
    func mountsAwaitedShareFirst(
        to path: VFSPath,
        focus child: VFSPath?,
        recordHistory: Bool,
        unasked: Bool
    ) -> Bool {
        switch shareMountVerdict(to: path, unasked: unasked) {
        case .listNow:
            return false
        case let .standDown(reason):
            standDown(tabs[activeTabIndex], reason: reason)
            return true
        case let .connect(endpoint):
            guard let share = endpoint.smbShare else { return false }
            mountAwaitedShare(
                share,
                thenOpen: path,
                focus: child,
                recordHistory: recordHistory,
                unasked: unasked
            )
            return true
        }
    }

    /// The mount, and the navigation it was standing in front of. The tab keeps its place while it
    /// waits, as one does while a server lists. A failure is left on the pane, with an alert as
    /// well when somebody asked for the place.
    private func mountAwaitedShare(
        _ share: SMBLocation,
        thenOpen path: VFSPath,
        focus child: VFSPath?,
        recordHistory: Bool,
        unasked: Bool
    ) {
        loadToken += 1
        let token = loadToken
        let tab = tabs[activeTabIndex]
        let awaited = tab.awaitedShare
        let password = Self.storedPassword(forShare: share)
        Task {
            do {
                let mountPoint = try await SMBMounter.shared.mount(
                    share,
                    username: share.username,
                    password: password
                ).path
                // The share is this session's now, and `SMBMounter` answers for it from here on.
                tab.awaitedShare = nil
                guard token == loadToken, tabs[activeTabIndex] === tab else { return }
                // The share can come back under another name than the one written down
                // (`/Volumes/media-1`), and the folder is wherever it is now.
                let rehome = { (place: VFSPath) in
                    awaited?.holds(place) == true
                        ? PinnedShare.path(place, onMountPoint: mountPoint)
                        : place
                }
                navigate(
                    to: rehome(path),
                    focus: child.map(rehome),
                    recordHistory: recordHistory,
                    unasked: unasked
                )
            } catch {
                let detail = await shareMountFailure(error, mounting: share, password: password)
                guard token == loadToken, tabs[activeTabIndex] === tab else { return }
                standDown(tab, reason: .listingFailed(detail))
                if !unasked {
                    presentOperationFailure(message: connectFailureTitle(share.host), detail: detail)
                }
            }
        }
    }

    /// The share `tab` is inside, as the tab is written down: the mount this session reached, or the
    /// share a restored tab is still waiting on. `path` is where the tab is written down, when that is
    /// not the listing it shows.
    func shareEndpoint(for tab: PanelTab, at path: VFSPath? = nil) -> ServerEndpoint? {
        let path = path ?? tab.panel.path
        if let mounted = SMBMounter.shared.shareEndpoint(containing: path) { return mounted }
        guard let awaited = tab.awaitedShare, awaited.holds(path) else { return nil }
        return .smb(awaited.share)
    }
}
