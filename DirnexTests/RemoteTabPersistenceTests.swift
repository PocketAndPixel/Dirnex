import DirnexCore
import Foundation
import Testing

@testable import Dirnex

/// The **writing** half of restoring a server tab, and a saved workspace's version of it
/// (docs/LOCATION-SUPPORT.md ▸ "Session restore and workspaces drop remote tabs").
///
/// A `VFSBackendID` is only the account's descriptor — host, user, port, region — so a tab written
/// down with nothing else has no way back: it says nothing about the auth *method* or about an FTPS
/// certificate the user chose to trust. What is asserted here is that the endpoint the pane's own
/// `CompositeBackend` was connected with reaches the store, from a live connection and from a tab
/// that was restored and never opened.
///
/// Nothing here connects to anything: `connectSFTP` builds a transport object and files it under a
/// descriptor, which is bookkeeping. The endpoints are key-file SFTP, the one that needs no secret,
/// so the suite never touches the Keychain.
@Suite("Remote tab persistence")
@MainActor
struct RemoteTabPersistenceTests {
    private static let location = SFTPLocation(host: "example.com", username: "oleg")
    private static let endpoint = ServerEndpoint.sftp(
        location: location,
        authentication: .key(identityFile: "/Users/oleg/.ssh/id_ed25519")
    )
    private static var remotePath: VFSPath { VFSPath(backend: .sftp(location), path: "/var/log") }

    /// A pane keyed under a name of its own, so writing its state cannot touch the "left"/"right"
    /// panes of the developer running the tests — the app test target runs *inside the app* and
    /// shares its defaults domain (docs/NOTES.md ▸ Testing).
    private static func pane(at path: VFSPath) -> (PanelViewController, String) {
        let key = "reconnect-test-\(UUID().uuidString)"
        let vc = PanelViewController(
            backend: CompositeBackend(local: LocalBackend()),
            restoration: nil,
            defaultPath: path,
            restorationKey: key
        )
        vc.panel = Panel(path: path)
        return (vc, key)
    }

    /// A directory of its own for anything that will actually be **listed**.
    ///
    /// `restore(workspacePane:)` ends in `activateTab()`, which lists the active tab for real in the
    /// test host — and pointing that at the home directory is the one thing docs/NOTES.md says not to
    /// do: `/Users/oleg` wakes a recursive FSEvents stream every few hundred milliseconds and drags
    /// IconServices through the table layout of every pane the host is keeping alive, which is what
    /// starves the neighbouring suites' bounded waits. An empty temp directory lists in microseconds
    /// and tells nobody anything.
    private static func scratchDirectory() throws -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("dirnex-workspace-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private static func read(_ key: String) -> PersistedPane? {
        defer { UserDefaults.standard.removeObject(forKey: "Dirnex.tabs." + key) }
        return TabPersistence.load(paneKey: key)
    }

    // MARK: - Session restore

    @Test("a live connection's endpoint is what gets written down")
    func liveConnectionIsPersisted() throws {
        let (vc, key) = Self.pane(at: Self.remotePath)
        let composite = try #require(vc.backend as? CompositeBackend)
        composite.connectSFTP(
            location: Self.location,
            authentication: .key(identityFile: "/Users/oleg/.ssh/id_ed25519")
        )
        vc.persistState()

        let stored = try #require(Self.read(key))
        #expect(stored.tabs.count == 1)
        #expect(stored.tabs.first?.vfsPath == Self.remotePath)
        #expect(stored.tabs.first?.serverEndpoint == Self.endpoint)
    }

    /// The half that is easy to lose: a restored tab nobody switched to has no live connection, so
    /// reading only the composite would write it back down with no way home — and a session with
    /// five server tabs, of which one was looked at, would come back with one.
    @Test("a restored tab that was never opened keeps its way home across a second quit")
    func unopenedRestoredTabSurvivesASecondQuit() throws {
        let (vc, key) = Self.pane(at: Self.remotePath)
        vc.tabs[0].pendingConnection = Self.endpoint
        vc.persistState()

        let stored = try #require(Self.read(key))
        #expect(stored.tabs.first?.serverEndpoint == Self.endpoint)
    }

    @Test("a local tab writes no endpoint at all")
    func localTabWritesNoEndpoint() throws {
        let scratch = try Self.scratchDirectory()
        defer { try? FileManager.default.removeItem(at: scratch) }
        let (vc, key) = Self.pane(at: .local(scratch.path))
        vc.persistState()

        let stored = try #require(Self.read(key))
        #expect(stored.tabs.first?.serverEndpoint == nil)
    }

    /// A **nested** archive is a temp extraction of a member of the enclosing archive, so the file
    /// its backend names is gone by the next launch — and the registry that knows where it came from
    /// is session-scoped, so a temp file that happened to survive would browse as a top-level
    /// archive with a broken way out. Refused on the way *down*, where the fact is still known.
    ///
    /// The narrowness control rides in the same test: a **top-level** archive tab is written, which
    /// is the whole point of widening the restore.
    @Test("a top-level archive tab is written down; a nested one is not")
    func nestedArchiveTabIsWithheld() throws {
        let outer = "/Users/oleg/pkg.zip"
        let extracted = NSTemporaryDirectory() + "inner-\(UUID().uuidString).zip"
        let (vc, key) = Self.pane(at: VFSPath(backend: .archive(forArchiveAt: outer), path: "/docs"))
        let host = StubPanelHost()
        host.nestedArchiveRegistry.record(
            mountOnDiskPath: extracted,
            origin: VFSPath(backend: .archive(forArchiveAt: outer), path: "/docs/inner.zip")
        )
        vc.host = host
        vc.tabs.append(PanelTab(path: VFSPath(
            backend: .archive(forArchiveAt: extracted),
            path: "/"
        )))
        vc.persistState()

        let stored = try #require(Self.read(key))
        #expect(stored.tabs.count == 1)
        #expect(stored.tabs.first?.vfsPath.backend.archivePath == outer)
    }

    // MARK: - Workspaces

    @Test("a workspace snapshot carries the endpoint of a tab on a server")
    func workspaceSnapshotCarriesTheEndpoint() throws {
        let (vc, _) = Self.pane(at: Self.remotePath)
        let composite = try #require(vc.backend as? CompositeBackend)
        composite.connectSFTP(
            location: Self.location,
            authentication: .key(identityFile: "/Users/oleg/.ssh/id_ed25519")
        )

        let snapshot = vc.workspaceSnapshot()
        #expect(snapshot.tabs.count == 1)
        #expect(snapshot.tabs.first?.path == Self.remotePath)
        #expect(snapshot.tabs.first?.serverEndpoint == Self.endpoint)
    }

    /// Restoring a workspace brings a server tab back holding its endpoint — the tab is opened by
    /// whichever navigation first wants it, exactly as at launch. The active tab is deliberately
    /// the **local** one so the assertion needs no listing of a server that does not exist.
    @Test("a saved workspace brings its server tab back")
    func workspaceRestoreBringsBackAServerTab() throws {
        let scratch = try Self.scratchDirectory()
        defer { try? FileManager.default.removeItem(at: scratch) }
        let (vc, _) = Self.pane(at: .local(scratch.path))
        vc.restore(workspacePane: WorkspacePane(
            tabs: [
                WorkspaceTab(path: .local(scratch.path)),
                WorkspaceTab(path: Self.remotePath, endpoint: Self.endpoint)
            ],
            activeTabIndex: 0
        ))
        #expect(vc.tabs.count == 2)
        #expect(vc.tabs[1].panel.path == Self.remotePath)
        #expect(vc.tabs[1].pendingConnection == Self.endpoint)
    }

    /// A workspace saved before endpoints existed, or one naming a server it has no way back to,
    /// drops that tab rather than opening a chip nothing can fill — the same rule the session
    /// restore keeps, through the same `TabRestorePolicy`.
    @Test("a workspace tab with no endpoint is dropped")
    func workspaceTabWithoutAnEndpointIsDropped() throws {
        let scratch = try Self.scratchDirectory()
        defer { try? FileManager.default.removeItem(at: scratch) }
        let (vc, _) = Self.pane(at: .local(scratch.path))
        vc.restore(workspacePane: WorkspacePane(
            tabs: [
                WorkspaceTab(path: .local(scratch.path)),
                WorkspaceTab(path: Self.remotePath)
            ],
            activeTabIndex: 0
        ))
        #expect(vc.tabs.count == 1)
        #expect(vc.tabs[0].panel.path == .local(scratch.path))
    }
}
