import DirnexCore
import Foundation
import Testing

@testable import Dirnex

/// The decision a navigation makes before it can list a **restored** server tab: connect, stand
/// down, or nothing to do (docs/LOCATION-SUPPORT.md ▸ "Session restore and workspaces drop remote
/// tabs").
///
/// Every case here is reachable headlessly because registering a connection is pure bookkeeping —
/// no round trip, no window — and because the refresh floor is a **defaulted parameter** rather
/// than a live read inside the rule. A rule that fetched its own preference would have exactly one
/// test case, the state this machine happens to be in, and its narrowness control would pass while
/// proving nothing (docs/NOTES.md ▸ Testing).
///
/// The endpoints are all key-file SFTP and anonymous FTP: those are the two that need no secret, so
/// the suite never reads or writes the developer's own Keychain — which is the item the S3 live
/// suites had to learn to put back (docs/NOTES.md ▸ Testing).
@Suite("Pane reconnect")
@MainActor
struct PaneReconnectTests {
    private static let location = SFTPLocation(host: "example.com", username: "oleg")
    private static let endpoint = ServerEndpoint.sftp(
        location: location,
        authentication: .key(identityFile: "/Users/oleg/.ssh/id_ed25519")
    )
    private static var remotePath: VFSPath { VFSPath(backend: .sftp(location), path: "/var/log") }

    /// A pane on a real `CompositeBackend` — the routing pane the app actually holds, since a
    /// `LocalBackend` pane answers for every path itself and could not see this decision at all.
    /// The view is never loaded, so nothing lists and no window is built.
    private static func pane(at path: VFSPath, pendingConnection: ServerEndpoint?)
        -> PanelViewController {
        let vc = PanelViewController(
            backend: CompositeBackend(local: LocalBackend()),
            restoration: nil,
            defaultPath: path,
            restorationKey: nil
        )
        // `panel` *is* `tabs[activeTabIndex].panel` (a computed accessor), so one assignment does it.
        vc.panel = Panel(path: path)
        vc.tabs[0].pendingConnection = pendingConnection
        return vc
    }

    // MARK: - Nothing to do

    @Test("a local tab connects nothing")
    func localNeedsNothing() {
        let vc = Self.pane(at: .local(NSTemporaryDirectory()), pendingConnection: nil)
        #expect(vc.reconnectVerdict(to: vc.panel.path, unasked: true, floor: 15) == .listNow)
    }

    /// A pane whose connection went away *mid-session* is not a restore: it has no pending
    /// endpoint, and the honest answer is to let the listing fail the way it always has, with
    /// `serverNotConnected` naming the account.
    @Test("a server tab with no pending endpoint is left to fail as it always did")
    func noPendingEndpointFallsThrough() {
        let vc = Self.pane(at: Self.remotePath, pendingConnection: nil)
        #expect(vc.reconnectVerdict(to: Self.remotePath, unasked: false, floor: 15) == .listNow)
    }

    /// A second navigation inside the same account must not re-register: the first one connected,
    /// and `CompositeBackend.isConnected` is what says so.
    @Test("an already-connected account is not reconnected")
    func alreadyConnectedIsLeftAlone() throws {
        let vc = Self.pane(at: Self.remotePath, pendingConnection: Self.endpoint)
        let composite = try #require(vc.backend as? CompositeBackend)
        #expect(vc.canListAfterReconnecting(to: Self.remotePath, unasked: false, floor: 0))
        #expect(composite.isConnected(Self.remotePath.backend))
        #expect(vc.reconnectVerdict(to: Self.remotePath, unasked: false, floor: 15) == .listNow)
    }

    // MARK: - Connecting

    @Test("a restored server tab connects when somebody asks for it")
    func askedConnects() throws {
        let vc = Self.pane(at: Self.remotePath, pendingConnection: Self.endpoint)
        let composite = try #require(vc.backend as? CompositeBackend)
        #expect(!composite.isConnected(Self.remotePath.backend))

        #expect(
            vc.reconnectVerdict(to: Self.remotePath, unasked: false, floor: 0)
                == .connect(Self.endpoint)
        )
        #expect(vc.canListAfterReconnecting(to: Self.remotePath, unasked: false, floor: 0))
        // Registered, and registered as the thing that was stored — so a later quit writes the
        // same endpoint back down rather than losing the auth method.
        #expect(composite.endpoint(for: Self.remotePath.backend) == Self.endpoint)
        #expect(vc.tabs[0].offlineReason == nil)
    }

    /// The ordinary relaunch: nobody pressed anything, and the tab still comes back connected —
    /// which is what "restore my session" means at every floor but the one that says otherwise.
    @Test("a relaunch connects at the default floor")
    func unaskedConnectsAtTheDefaultFloor() {
        let vc = Self.pane(at: Self.remotePath, pendingConnection: Self.endpoint)
        #expect(
            vc.reconnectVerdict(
                to: Self.remotePath,
                unasked: true,
                floor: RemoteRefreshPolicy.defaultFloor
            ) == .connect(Self.endpoint)
        )
    }

    // MARK: - Standing down

    /// Settings ▸ Panels promises in writing that 0 means "never contact a server unasked", and a
    /// relaunch onto a restored tab is unasked however true it is that the tab was left open.
    @Test("a zero floor withholds the connection a relaunch would open by itself")
    func zeroFloorStandsDownAtLaunch() throws {
        let vc = Self.pane(at: Self.remotePath, pendingConnection: Self.endpoint)
        let composite = try #require(vc.backend as? CompositeBackend)
        #expect(
            vc.reconnectVerdict(to: Self.remotePath, unasked: true, floor: 0)
                == .standDown(.serversNotContactedUnasked)
        )
        #expect(!vc.canListAfterReconnecting(to: Self.remotePath, unasked: true, floor: 0))
        #expect(!composite.isConnected(Self.remotePath.backend))
        #expect(vc.tabs[0].offlineReason == .serversNotContactedUnasked)
        // Left unloaded on purpose, so the next activation tries again rather than showing an
        // empty folder for the rest of the session.
        #expect(vc.tabs[0].hasLoaded == false)
        // And the endpoint is kept, so the next quit writes the tab back down with a way home.
        #expect(vc.tabs[0].pendingConnection == Self.endpoint)
    }

    /// The narrowness control for the rule above, and the half that makes the setting mean what its
    /// own footer says: 0 is "never contact a server **unasked**", not "never contact a server". A
    /// gesture — switching to the tab, clicking a crumb, ⌘L — connects at any floor, which is also
    /// the only way out of the state the previous test leaves the pane in.
    @Test("a gesture connects the same tab at the same zero floor")
    func zeroFloorStillConnectsWhenAsked() throws {
        let vc = Self.pane(at: Self.remotePath, pendingConnection: Self.endpoint)
        let composite = try #require(vc.backend as? CompositeBackend)
        #expect(!vc.canListAfterReconnecting(to: Self.remotePath, unasked: true, floor: 0))

        #expect(vc.canListAfterReconnecting(to: Self.remotePath, unasked: false, floor: 0))
        #expect(composite.isConnected(Self.remotePath.backend))
    }

    /// An endpoint whose secret is gone cannot be reconnected unattended, and a restore must raise
    /// nothing — so the honest outcome is a tab that came back and says why it is empty. Password
    /// auth with nothing filed under this host is the state: the fixture never writes a Keychain
    /// item, so the lookup genuinely misses.
    @Test("a password endpoint with no stored secret stands down instead of connecting")
    func missingSecretStandsDown() throws {
        let host = "reconnect-test-\(UUID().uuidString).invalid"
        let location = SFTPLocation(host: host, username: "oleg")
        let path = VFSPath(backend: .sftp(location), path: "/var/log")
        let vc = Self.pane(
            at: path,
            pendingConnection: .sftp(location: location, authentication: .password)
        )
        let composite = try #require(vc.backend as? CompositeBackend)
        #expect(
            vc.reconnectVerdict(to: path, unasked: false, floor: 15)
                == .standDown(.credentialMissing)
        )
        #expect(!vc.canListAfterReconnecting(to: path, unasked: false, floor: 15))
        #expect(!composite.isConnected(path.backend))
        #expect(vc.tabs[0].offlineReason == .credentialMissing)
    }

    /// A stand-down leaves the pane drawing **its own place, empty** — never rows it can no longer
    /// vouch for. The pane it stands down is the active tab, whose `panel` the controller *is*, so
    /// the rows on screen at that moment are this tab's from a previous session's listing or the
    /// outgoing tab's mid-switch; either way they are not what this account is showing now, and
    /// leaving them under the account's crumbs is worse than an empty pane by a long way.
    @Test("a stood-down tab shows its own path with no rows")
    func standDownRendersTheTabsOwnPlace() {
        let vc = Self.pane(at: Self.remotePath, pendingConnection: Self.endpoint)
        let stale = FileEntry(
            path: VFSPath(backend: Self.remotePath.backend, path: "/var/log/old.txt"),
            name: "old.txt",
            kind: .file,
            byteSize: 0,
            modificationDate: Date(timeIntervalSince1970: 0),
            creationDate: Date(timeIntervalSince1970: 0),
            isHidden: false,
            permissions: 0o644,
            inode: 0
        )
        vc.panel.setModel(DirectoryModel(
            listing: DirectoryListing(path: Self.remotePath, entries: [stale])
        ))
        #expect(vc.panel.count == 1)

        #expect(!vc.canListAfterReconnecting(to: Self.remotePath, unasked: true, floor: 0))
        #expect(vc.panel.path == Self.remotePath)
        #expect(vc.panel.isEmpty)
    }

    /// The reason has to reach the **screen**, and the status line is the only surface saying that
    /// the empty pane is not an empty folder — a restore raises no alert, by design. Read off the
    /// live label rather than off the enum, since what could silently go wrong is the *drawing*:
    /// without the branch, the counts below it report "0 items" about a server nobody asked about.
    ///
    /// Asserted as a **difference** rather than against the English words. The app test target runs
    /// inside the app and inherits whatever `AppleLanguages` the developer pinned Dirnex to, so a
    /// test that spelled the sentence would fail on the machine of anyone checking a translation
    /// (docs/NOTES.md ▸ Localization). The pane with and without the reason is the same pane in the
    /// same language, so the two lines differing is the whole claim — in either direction.
    @Test("a stood-down tab's reason is what the status line draws")
    func reasonReachesTheStatusLine() {
        let vc = Self.pane(at: Self.remotePath, pendingConnection: Self.endpoint)
        #expect(!vc.canListAfterReconnecting(to: Self.remotePath, unasked: true, floor: 0))
        let stoodDown = vc.statusLabel.stringValue
        #expect(!stoodDown.isEmpty)

        // The same pane, same rows, reason gone: the line has to go back to the item count.
        vc.tabs[0].offlineReason = nil
        vc.updateChrome()
        #expect(vc.statusLabel.stringValue != stoodDown)
        #expect(!vc.statusLabel.stringValue.isEmpty)
    }

    /// The reason is cleared by the load that succeeds, so re-entering a stood-down tab removes it
    /// with nothing to reset by hand.
    @Test("a later successful listing clears the reason")
    func reasonIsClearedByASuccessfulLoad() {
        let vc = Self.pane(at: Self.remotePath, pendingConnection: Self.endpoint)
        #expect(!vc.canListAfterReconnecting(to: Self.remotePath, unasked: true, floor: 0))
        #expect(vc.tabs[0].offlineReason != nil)

        vc.tabs[0].offlineReason = nil
        #expect(vc.reconnectVerdict(to: Self.remotePath, unasked: false, floor: 0)
            == .connect(Self.endpoint))
    }
}
