import AppKit
import DirnexCore

/// Why a restored tab is showing nothing — the state that replaces the load-failure sheet for a
/// load nobody asked for.
///
/// A named reason rather than a sentence, so the decision that produces it is testable without
/// asserting displayed text, and so a translated build cannot change what the code does — the trap
/// docs/NOTES.md records for `enableEscapeToCancel`'s English button titles. The words are chosen at
/// the display site (`PanelViewController+Chrome`).
enum TabOfflineReason: Equatable {
    /// Settings ▸ Panels is set to never contact a server unasked, and a relaunch is unasked.
    case serversNotContactedUnasked
    /// There is no secret to reconnect with — never saved, or since cleared from the Keychain.
    case credentialMissing
    /// The connection was re-established and the listing failed anyway; the payload is the ordinary
    /// `VFSErrorText` sentence, so a refused bucket reads as a refused bucket.
    case listingFailed(String)
}

/// What a navigation has to do before it can list.
enum ReconnectVerdict: Equatable {
    /// Nothing: a local path, an archive, or a server that is already connected.
    case listNow
    /// Register this endpoint on the pane's backend first.
    case connect(ServerEndpoint)
    /// Do not list; leave the pane saying why.
    case standDown(TabOfflineReason)
}

/// Bringing a **restored** tab's connection back — session restore's and a saved workspace's half
/// of `PanelViewController+Connect` (docs/LOCATION-SUPPORT.md ▸ "Session restore and workspaces
/// drop remote tabs").
///
/// Nothing here talks to a server. Registering a connection on the pane's `CompositeBackend` is
/// pure bookkeeping — a credential plus coordinates — and the round trip happens where it always
/// did, in the listing that follows. That is what makes this synchronous, what keeps the region-301
/// correction and the path-style retry out of it (a restored bucket's path is already the one an
/// earlier connect *settled on*, so there is nothing left to correct), and what makes the two
/// failures worth telling apart: a connection that cannot be registered has no secret, and one that
/// registers and then cannot list has a server problem.
///
/// **The seam is `navigate`, not `activateTab`,** and that is the design rather than a convenience.
/// Every way back into a tab — switching to it, clicking a crumb in its path bar, ⌘L, back/forward
/// — is a navigation, so putting the reconnect there means one definition of "open this place
/// again" instead of one for the launch path and another for each gesture. It is also what gives a
/// tab that came back disconnected a way out with no new UI: any of those gestures connects it.
extension PanelViewController {
    /// Make sure `path` can be listed, and say whether the navigation may go ahead.
    ///
    /// `false` means the pane has been left showing why it cannot — never that something failed
    /// silently.
    ///
    /// `floor` is handed straight to ``reconnectVerdict(to:unasked:floor:)`` and carries that
    /// method's default for the same reason: the app test target runs *inside the app* and reads the
    /// developer's own preferences, so a test of the launch path that did not state the floor would
    /// pass or fail depending on whose Mac it ran on (docs/NOTES.md ▸ Localization, the same trap
    /// with `AppleLanguages`).
    func canListAfterReconnecting(
        to path: VFSPath,
        unasked: Bool,
        floor: TimeInterval = AppPreferences.shared.remoteRefreshFloor
    ) -> Bool {
        switch reconnectVerdict(to: path, unasked: unasked, floor: floor) {
        case .listNow:
            return true
        case let .connect(endpoint):
            guard let composite = backend as? CompositeBackend else { return true }
            register(endpoint, on: composite)
            return true
        case let .standDown(reason):
            standDown(tabs[activeTabIndex], reason: reason)
            return false
        }
    }

    /// The decision on its own: what this navigation owes before it can list.
    ///
    /// `unasked` is the launch activation and nothing else. Settings ▸ Panels promises that a floor
    /// of 0 means "never contact a server unasked", and a relaunch onto a restored tab is unasked
    /// however true it is that the tab was left open — so at 0 the tab still comes back, and waits
    /// for a gesture. At any other floor it connects, because that is what "restore my session"
    /// means.
    ///
    /// The floor is a **defaulted parameter** rather than a read inside the rule, which is the
    /// difference between a decision with two reachable cases and one with however many the machine
    /// running the tests happens to be in (docs/NOTES.md ▸ Testing). Production callers pay nothing:
    /// Swift evaluates a default argument at each call.
    ///
    /// A remote path with a live connection, or with **no** pending endpoint, answers `.listNow` —
    /// the second deliberately, so a pane whose connection went away mid-session still fails the way
    /// it always has, with `serverNotConnected` naming the account. That is a different situation
    /// from a restore and it already has an answer.
    func reconnectVerdict(
        to path: VFSPath,
        unasked: Bool,
        floor: TimeInterval = AppPreferences.shared.remoteRefreshFloor
    ) -> ReconnectVerdict {
        guard path.backend.isRemoteConnection,
              let composite = backend as? CompositeBackend,
              !composite.isConnected(path.backend),
              let endpoint = tabs[activeTabIndex].pendingConnection,
              case .connection = TabRestorePolicy.requirement(for: path, endpoint: endpoint)
        else { return .listNow }

        guard !unasked || RemoteRefreshPolicy.contactsServersUnasked(floor: floor) else {
            return .standDown(.serversNotContactedUnasked)
        }
        guard hasSecret(for: endpoint) else { return .standDown(.credentialMissing) }
        return .connect(endpoint)
    }

    /// Record why a restored tab's *listing* failed, in place of the alert a gesture would get.
    ///
    /// Same rule as `standDown`, one outcome later: the connection registered and the server did not
    /// answer, or answered a refusal. The sentence is the ordinary one — `VFSErrorText` is the single
    /// source for these — so a wrong key reads as a wrong key rather than as "couldn't restore".
    func recordRestoreFailure(_ error: Error, in tab: PanelTab) {
        tab.offlineReason = .listingFailed(describe(error))
        updateChrome()
    }

    /// Leave the pane showing why a restored tab could not be brought back, without an alert.
    ///
    /// A restore is a load the app performs on its own schedule, so there is nobody waiting for the
    /// answer — the rule `presentLoadFailure` already states, arriving one step earlier, before a
    /// listing is even attempted. The pane is given an **empty listing at the tab's own path** so it
    /// draws the place it is supposed to be showing (the right crumbs, the right chip, no rows)
    /// rather than the previous tab's contents, and `hasLoaded` is deliberately left `false` so the
    /// next activation tries again.
    private func standDown(_ tab: PanelTab, reason: TabOfflineReason) {
        // The pane is now showing this, so anything still in flight for it is answering a question
        // nobody is asking — the same invalidation `navigate` performs before its own load.
        loadToken += 1
        tab.offlineReason = reason
        panel.setModel(DirectoryModel(
            listing: DirectoryListing(path: panel.path, entries: []),
            sort: panel.model.sort,
            showHidden: AppPreferences.shared.showHidden
        ))
        applyViewMode()
        cursorOnParentRow = false
        reloadEverything()
        refreshTabBar()
        host?.panelDidNavigate(self)
    }

    // MARK: - The Keychain half

    /// Whether there is a secret to reconnect `endpoint` with.
    ///
    /// The rules are the sidebar connect's, deliberately: a saved server whose password was never
    /// stored (or has since been cleared) opens the prefilled sheet there, and the honest equivalent
    /// for a restore — which must raise nothing — is to come back disconnected and say so. Key-file
    /// SFTP and anonymous FTP need no secret at all, so they reconnect unattended, which is most of
    /// what an SFTP session actually is.
    private func hasSecret(for endpoint: ServerEndpoint) -> Bool {
        switch endpoint {
        case let .sftp(location, authentication):
            guard case .password = authentication else { return true }
            return SecretKeychain.password(for: location) != nil
        case let .ftp(location, authentication, _):
            guard case .password = authentication else { return true }
            return SecretKeychain.password(for: location) != nil
        case let .s3(location):
            return SecretKeychain.password(for: location) != nil
        case let .s3Account(account):
            return SecretKeychain.password(for: account) != nil
        // An SMB share is a `/Volumes/…` tree, so a pane on one is `.local` and never reaches here;
        // `TabRestorePolicy` refuses an SMB endpoint against a remote path before this can be asked.
        case .smb:
            return false
        }
    }

    /// Register `endpoint` on `composite`. Called only after ``hasSecret(for:)`` has said there is
    /// something to register with, so a missing secret is a *decision* above rather than a failure
    /// here — which is what keeps "why is this tab not connected" one question with one answer.
    private func register(_ endpoint: ServerEndpoint, on composite: CompositeBackend) {
        switch endpoint {
        case let .sftp(location, authentication):
            composite.connectSFTP(
                location: location,
                authentication: authentication,
                password: SecretKeychain.password(for: location)
            )
        case let .ftp(location, authentication, trustedPublicKey):
            composite.connectFTP(
                location: location,
                authentication: authentication,
                password: SecretKeychain.password(for: location) ?? "",
                trustedPublicKey: trustedPublicKey
            )
        case let .s3(location):
            guard let secret = SecretKeychain.password(for: location) else { return }
            composite.connectS3(location: location, secretAccessKey: secret)
        case let .s3Account(account):
            guard let secret = SecretKeychain.password(for: account) else { return }
            composite.connectS3Account(account: account, secretAccessKey: secret)
        case .smb:
            return
        }
    }
}
