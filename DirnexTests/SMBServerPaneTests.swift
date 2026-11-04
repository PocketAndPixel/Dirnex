import DirnexCore
import Foundation
import Testing

@testable import Dirnex

/// A stand-in for the NetFS enumerator: the shares it answers, and how many sessions it was asked for.
private final class StubShareEnumerator: SMBShareEnumerating, @unchecked Sendable {
    let answer: [SMBShare]
    private(set) var calls = 0

    init(_ answer: [SMBShare]) {
        self.answer = answer
    }

    func shares() throws -> [SMBShare] {
        calls += 1
        return answer
    }
}

/// A backend whose per-path answer is what a gate reads, as `CompositeBackend`'s is: the same shape
/// as `SyncReachTests`' own, which is private to that file.
private struct PerPathBackend: VFSBackend {
    let perPath: [VFSPath: VFSCapabilities]

    var id: VFSBackendID { .local }
    var capabilities: VFSCapabilities { [.read, .write, .trash, .watch] }

    func capabilities(for path: VFSPath) -> VFSCapabilities { perPath[path] ?? [] }

    func listDirectory(at path: VFSPath) throws -> [FileEntry] { [] }

    func stat(at path: VFSPath) throws -> FileEntry {
        throw VFSError.notFound(path)
    }
}

/// An SMB server's shares as a pane (PLAN.md §M35): the routing, the gates, the names, and the
/// sentences. NetFS itself is exercised live; registering a server costs no session, so none of this
/// needs one.
@Suite("SMB server pane")
@MainActor
struct SMBServerPaneTests {
    private static let server = SMBLocation(host: "nas", username: "dirnex-test")
    private static var root: VFSPath { VFSPath(backend: .smbServer(server), path: "/") }
    private static var media: VFSPath { VFSPath(backend: .smbServer(server), path: "/media") }

    // MARK: - Routing

    @Test(
        "a registered server lists through the composite, read-only, with its endpoint and password"
    )
    func routesToTheRegisteredServer() throws {
        let composite = CompositeBackend(local: LocalBackend())
        #expect(composite.capabilities(for: Self.root) == .read)
        #expect(throws: (any Error).self) { try composite.listDirectory(at: Self.root) }
        #expect(!composite.isConnected(.smbServer(Self.server)))

        let enumerator = StubShareEnumerator([SMBShare(name: "home"), SMBShare(name: "media")])
        composite.register(
            smbServer: SMBServerBackend(server: Self.server, enumerator: enumerator),
            password: "secret"
        )

        #expect(try composite.listDirectory(at: Self.root).map(\.name) == ["home", "media"])
        #expect(composite.capabilities(for: Self.root) == .read)
        #expect(composite.endpoint(for: .smbServer(Self.server)) == .smb(Self.server))
        #expect(composite.smbServerConnection(for: .smbServer(Self.server))?.password == "secret")
        #expect(enumerator.calls == 1)
    }

    @Test("another account on the same server is another connection")
    func accountsAreSeparateConnections() {
        let composite = CompositeBackend(local: LocalBackend())
        composite.register(
            smbServer: SMBServerBackend(server: Self.server, enumerator: StubShareEnumerator([])),
            password: nil
        )
        let other = SMBLocation(host: "nas", username: "oleg")
        #expect(throws: (any Error).self) {
            try composite.listDirectory(at: VFSPath(backend: .smbServer(other), path: "/"))
        }
    }

    // MARK: - Rows and gates

    @Test("a row on the list is a share row; the list's root and a mounted folder are not")
    func shareRows() {
        #expect(Self.media.isSMBShareRow)
        #expect(!Self.root.isSMBShareRow)
        #expect(!VFSPath.local("/Volumes/media").isSMBShareRow)
    }

    @Test("Return on a share row mounts it rather than walking into it")
    func returnOnAShareMounts() {
        let pane = Self.pane(at: Self.root)
        let row = FileEntry(
            path: Self.media,
            name: "media",
            kind: .directory,
            byteSize: 0,
            modificationDate: FileEntry.unknownDate,
            creationDate: FileEntry.unknownDate,
            isHidden: false,
            permissions: 0o755,
            inode: 0
        )
        #expect(pane.smbShareToEnter(for: row) == Self.media)

        let folder = FileEntry(
            path: .local("/Volumes/media/films"),
            name: "films",
            kind: .directory,
            byteSize: 0,
            modificationDate: .now,
            creationDate: .now,
            isHidden: false,
            permissions: 0o755,
            inode: 1
        )
        #expect(pane.smbShareToEnter(for: folder) == nil)
    }

    @Test("a list of shares does not take part in Synchronize")
    func refusedBySync() {
        #expect(!PanelViewController.canSync(Self.pane(at: Self.root)))
    }

    @Test("a folder nobody mounted through Dirnex goes up to its parent, not to a server")
    func onlyDirnexMountsLeaveForTheServer() {
        let pane = Self.pane(at: .local("/Volumes"))
        #expect(!pane.leavesShareForItsServer)
        #expect(SMBMounter.shared.share(mountedAt: "/Volumes/nothing-mounted-here") == nil)
    }

    // MARK: - Names

    @Test("the list is named by its account and host, a guest's by the host alone")
    func names() {
        #expect(Self.root.displayName == "dirnex-test@nas")
        #expect(
            VFSPath(backend: .smbServer(SMBLocation(host: "nas")), path: "/").displayName == "nas"
        )
        #expect(Self.media.displayName == "media")
        #expect(PathBarView.rootSymbolName(for: Self.root)
            == SidebarPlacePresentation.serverSymbolName(for: .smb))
    }

    // MARK: - A saved server with no share

    @Test("a saved server with no share asks for its server, with its password or as a guest")
    func savedServerConnectsToTheList() {
        let saved = ServerConnection(name: "NAS", endpoint: .smb(Self.server))
        guard case let .smb(request)? = PanelViewController.connectRequest(
            for: saved,
            secret: "secret",
            inNewTab: false
        ) else {
            Issue.record("expected an SMB request")
            return
        }
        #expect(request.location.share == nil)
        #expect(request.password == "secret")

        let guest = ServerConnection(name: "Guest", endpoint: .smb(SMBLocation(host: "nas")))
        guard case let .smb(guestRequest)? = PanelViewController.connectRequest(
            for: guest,
            secret: nil,
            inNewTab: false
        ) else {
            Issue.record("expected an SMB request")
            return
        }
        #expect(guestRequest.password == nil)
    }

    // MARK: - Helpers

    private static func pane(at path: VFSPath) -> PanelViewController {
        let backend = PerPathBackend(perPath: [path: .read])
        let pane = PanelViewController(
            backend: backend,
            restoration: nil,
            defaultPath: path,
            restorationKey: nil
        )
        pane.panel = Panel(model: DirectoryModel(listing: DirectoryListing(path: path, entries: [])))
        return pane
    }
}

/// What a refused share or account says (PLAN.md §M35). The status alone can only hedge; once the
/// server's list has been asked, the sentence says which reading it is.
@Suite("SMB refusal sentences")
struct SMBRefusalSentenceTests {
    private static let share = SMBLocation(host: "nas", share: "Photos", username: "dirnex-test")
    private static let guestShare = SMBLocation(host: "nas", share: "Photos")

    private static func sentence(_ location: SMBLocation, absence: SMBShareAbsence) -> String? {
        var error = SMBMountError(status: ENOENT, location: location)
        error.absence = absence
        return error.errorDescription
    }

    @Test("a listed share that will not mount is a permission, said plainly")
    func notPermitted() {
        #expect(Self.sentence(Self.share, absence: .notPermitted)
            == "“dirnex-test” doesn’t have permission to use “Photos” on “nas”.")
        #expect(Self.sentence(Self.guestShare, absence: .notPermitted)
            == "A guest connection doesn’t have permission to use “Photos” on “nas”.")
    }

    @Test("a share the list leaves out is one the server doesn't offer this account")
    func notOffered() {
        #expect(Self.sentence(Self.share, absence: .notOffered)
            == "“nas” doesn’t offer a shared folder named “Photos” to “dirnex-test”.")
        #expect(Self.sentence(Self.guestShare, absence: .notOffered)
            == "“nas” doesn’t offer a shared folder named “Photos” to guests.")
    }

    @Test("with no list the sentence still names both readings")
    func unknownKeepsTheHedge() {
        let sentence = Self.sentence(Self.share, absence: .unknown) ?? ""
        #expect(sentence.contains("may not exist"))
        #expect(sentence.contains("may not have permission"))
    }

    @Test("an account refused outright is named, a guest is told guests are off")
    func accountRestricted() {
        let server = SMBLocation(host: "nas", username: "dirnex-test")
        #expect(SMBMountError(status: -5999, location: server).errorDescription
            == "“dirnex-test” can’t sign in to “nas” right now. The account may be disabled, or "
            + "locked after too many failed attempts.")
        #expect(SMBMountError(status: -5999, location: SMBLocation(host: "nas")).errorDescription
            == "“nas” doesn’t allow guest access. Enter a username and password.")
    }
}
