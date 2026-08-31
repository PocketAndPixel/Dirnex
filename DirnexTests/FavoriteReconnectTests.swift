import DirnexCore
import Foundation
import Testing

@testable import Dirnex

/// What a pinned folder on a connected account carries, and what picking one does about it
/// (docs/LOCATION-SUPPORT.md ▸ the Favorites row).
///
/// A pin used to be a `VFSPath` and nothing else, so a folder on a server survived a quit as a
/// sidebar row that could never be opened again: a `VFSBackendID` is the account's descriptor and
/// says nothing about the auth method. Both halves of closing that are here — what a pin *records*
/// when it is made, and what it *hands the navigation* when it is picked.
///
/// Reachable headlessly for the reasons `PaneReconnectTests` states: registering a connection is
/// pure bookkeeping with no round trip, the view is never loaded so nothing lists and no window is
/// built, and every endpoint is key-file SFTP or anonymous FTP — the two that need no secret — so
/// the suite never touches the developer's own Keychain. Nothing here writes `FavoritesStore`
/// either, which in a target that runs inside the app is the real sidebar (docs/NOTES.md ▸ Testing).
@Suite("Favorite reconnect")
@MainActor
struct FavoriteReconnectTests {
    private static let location = SFTPLocation(host: "example.com", username: "oleg")
    private static let endpoint = ServerEndpoint.sftp(
        location: location,
        authentication: .key(identityFile: "/Users/oleg/.ssh/id_ed25519")
    )
    private static var remotePath: VFSPath { VFSPath(backend: .sftp(location), path: "/var/log") }

    /// A pane on a real `CompositeBackend` — the routing pane the app holds. A `LocalBackend` pane
    /// answers for every path itself and could not see any of this.
    private static func pane(at path: VFSPath) -> PanelViewController {
        let vc = PanelViewController(
            backend: CompositeBackend(local: LocalBackend()),
            restoration: nil,
            defaultPath: path,
            restorationKey: nil
        )
        vc.panel = Panel(path: path)
        return vc
    }

    // MARK: - What a pin records when it is made

    /// The pane's live connection is what a pin has to capture: it is the only object that knows
    /// what the connection was actually *made with*.
    @Test("pinning a folder on a connected account captures where to reconnect")
    func pinCapturesTheLiveEndpoint() {
        let vc = Self.pane(at: Self.remotePath)
        vc.tabs[0].pendingConnection = Self.endpoint
        // Registers the connection on the composite — bookkeeping only, no round trip.
        #expect(vc.canListAfterReconnecting(to: Self.remotePath, unasked: false, floor: 0))

        let pin = vc.currentFolderPin()
        #expect(pin.path == Self.remotePath)
        #expect(pin.serverEndpoint == Self.endpoint)
    }

    /// The narrowness half, and the one that keeps every ordinary pin byte-identical to what earlier
    /// builds wrote: a local folder records no endpoint at all.
    @Test("pinning a local folder records no endpoint")
    func localPinRecordsNothing() {
        let vc = Self.pane(at: .local(NSTemporaryDirectory()))
        #expect(vc.currentFolderPin().serverEndpoint == nil)
    }

    // MARK: - What picking one hands the navigation

    @Test("picking a pin on a server hands its endpoint to the navigation's reconnect")
    func pickingRecordsTheConnection() {
        let vc = Self.pane(at: .local(NSTemporaryDirectory()))
        let pin = FavoriteEntry(name: "Logs", path: Self.remotePath, endpoint: Self.endpoint)
        #expect(vc.recordPendingConnection(for: pin) == Self.endpoint)
        #expect(vc.tabs[0].pendingConnection == Self.endpoint)
    }

    /// The check that makes weighing the pair worthwhile rather than trusting the endpoint on sight.
    /// A pin is two fields of JSON in a defaults domain, so nothing but comparing them stops a jump
    /// from connecting to one account and then listing a path that belongs to another — which would
    /// draw a perfectly plausible listing under the wrong name.
    @Test("a pin whose endpoint is not its own account connects nothing")
    func mismatchedEndpointIsRefused() {
        let vc = Self.pane(at: .local(NSTemporaryDirectory()))
        let elsewhere = ServerEndpoint.ftp(
            location: FTPLocation(host: "ftp.example.org", username: "oleg"),
            authentication: .anonymous
        )
        let pin = FavoriteEntry(name: "Logs", path: Self.remotePath, endpoint: elsewhere)
        #expect(vc.recordPendingConnection(for: pin) == nil)
        #expect(vc.tabs[0].pendingConnection == nil)
    }

    /// Every remote pin in a user's store predates the field. It records nothing and is left to fail
    /// the way it always has — `serverNotConnected`, naming the account — rather than being made to
    /// look like a pin that could reconnect.
    @Test("a pin made before the endpoint existed connects nothing")
    func endpointlessRemotePinRecordsNothing() {
        let vc = Self.pane(at: .local(NSTemporaryDirectory()))
        #expect(vc.recordPendingConnection(for: FavoriteEntry(path: Self.remotePath)) == nil)
        #expect(vc.tabs[0].pendingConnection == nil)
    }

    /// A local pin must not disturb a tab that is already carrying a connection: picking Home out of
    /// a restored server tab is an ordinary navigation, not a reason to forget where it came from.
    @Test("picking a local pin leaves an existing pending connection alone")
    func localPickLeavesThePendingConnection() {
        let vc = Self.pane(at: Self.remotePath)
        vc.tabs[0].pendingConnection = Self.endpoint
        let home = FavoriteEntry(path: .local(NSTemporaryDirectory()))
        #expect(vc.recordPendingConnection(for: home) == nil)
        #expect(vc.tabs[0].pendingConnection == Self.endpoint)
    }
}
