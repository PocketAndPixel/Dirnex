import DirnexCore
import Foundation
import Testing

@testable import Dirnex

/// A stand-in for the NetFS enumerator: the shares it answers, and how many sessions it was asked for.
private final class CountingShareEnumerator: SMBShareEnumerating, @unchecked Sendable {
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

/// `..` at the root of a share Finder mounted goes up to that server's list, as the account the mount
/// names, with the cursor on the share (PLAN.md §M40 Slice 8). Before, only a share Dirnex had mounted
/// itself did, and Finder's went to `/Volumes`.
///
/// A temporary folder stands in for the mount, and `SMBMounter`'s mount-table seam names it as the
/// smbfs mount this Mac's table held for the NAS share Finder mounted on 2026-11-19, so nothing
/// reaches NetFS or the Keychain.
@Suite("Up from a share Finder mounted", .serialized)
@MainActor
struct ShareExitTests {
    private static let server = SMBLocation(host: "nas", username: "olegasd")

    private static func entry(_ mountPoint: String, source: String, type: String = "smbfs") -> MountTableEntry {
        MountTableEntry(mountPoint: mountPoint, isLocal: false, fileSystemType: type, source: source)
    }

    /// `entries` as the whole mount table for the length of `body`, then the real one again.
    private static func withMountTable(
        _ entries: [MountTableEntry],
        _ body: () async throws -> Void
    ) async rethrows {
        let mounter = SMBMounter.shared
        let mountTable = mounter.mountTable
        mounter.mountTable = { entries }
        defer { mounter.mountTable = mountTable }
        try await body()
    }

    @Test("the root of a share in the mount table is that share, as its account")
    func readsTheMountTable() async {
        let mounter = SMBMounter.shared
        await Self.withMountTable([
            Self.entry("/Volumes/media", source: "//olegasd@nas/media"),
            Self.entry("/Volumes/Movies", source: "//olegasd@nas/media/Movies"),
            Self.entry("/Volumes/Guest", source: "//GUEST:@nas/Public"),
            Self.entry("/Volumes/dav", source: "//olegasd@nas/media", type: "webdav")
        ]) {
            #expect(mounter.shareRoot(at: "/Volumes/media") == Self.server.share(named: "media"))
            #expect(
                mounter.shareRoot(at: "/Volumes/Guest") == SMBLocation(host: "nas", share: "Public")
            )
            #expect(mounter.shareRoot(at: "/Volumes/Movies") == nil, "a folder inside a share")
            #expect(mounter.shareRoot(at: "/Volumes/dav") == nil, "not an SMB mount")
            #expect(mounter.shareRoot(at: "/Volumes/media/films") == nil, "not the share's root")
            #expect(mounter.shareRoot(at: "/Volumes/elsewhere") == nil)
        }
    }

    @Test("connected lists again; a guest connects; an account uses its password or asks for one")
    func exits() {
        let share = Self.server.share(named: "media")
        #expect(PanelViewController.shareExit(for: share, isConnected: true) {
            Issue.record("a connected server needs no password")
            return nil
        } == .list)
        #expect(PanelViewController.shareExit(for: share, isConnected: false) { "secret" }
            == .connect(password: "secret"))
        #expect(PanelViewController.shareExit(for: share, isConnected: false) { nil }
            == .askForPassword)
        let guest = SMBLocation(host: "nas", share: "Public")
        #expect(PanelViewController.shareExit(for: guest, isConnected: false) {
            Issue.record("a guest has no password to look up")
            return nil
        } == .connect(password: nil))
    }

    @Test("`..` at a share Finder mounted lists its connected server with the cursor on the share")
    func goesUpToTheList() async throws {
        let mount = FileManager.default.temporaryDirectory
            .appendingPathComponent("ShareExit-\(UUID().uuidString)")
            .appendingPathComponent("media")
        try FileManager.default.createDirectory(at: mount, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: mount.deletingLastPathComponent()) }

        let composite = CompositeBackend(local: LocalBackend())
        let enumerator = CountingShareEnumerator([SMBShare(name: "home"), SMBShare(name: "media")])
        composite.register(
            smbServer: SMBServerBackend(server: Self.server, enumerator: enumerator),
            password: "secret"
        )
        let pane = PanelViewController(
            backend: composite,
            restoration: nil,
            defaultPath: .local(mount.path),
            restorationKey: nil
        )
        pane.loadViewIfNeeded()
        defer { pane.watcher = nil }
        try await settleUntil { pane.tabs[0].hasLoaded }

        try await Self.withMountTable([Self.entry(mount.path, source: "//olegasd@nas/media")]) {
            #expect(pane.leavesShareForItsServer)
            pane.goToParent()
            try await settleUntil { pane.panel.path.backend.isSMBServer && pane.tabs[0].hasLoaded }
            #expect(pane.panel.path == VFSPath(backend: .smbServer(Self.server), path: "/"))
            try await settleUntil { pane.panel.currentEntry?.name == "media" }
        }
        #expect(enumerator.calls == 1)
    }

    @Test("a folder no share is mounted at still goes up to its parent")
    func plainFolderGoesToItsParent() async {
        await Self.withMountTable([]) {
            let pane = PanelViewController(
                backend: CompositeBackend(local: LocalBackend()),
                restoration: nil,
                defaultPath: .local("/Volumes/media"),
                restorationKey: nil
            )
            pane.panel = Panel(model: DirectoryModel(listing: DirectoryListing(
                path: .local("/Volumes/media"),
                entries: []
            )))
            #expect(!pane.leavesShareForItsServer)
        }
    }
}
