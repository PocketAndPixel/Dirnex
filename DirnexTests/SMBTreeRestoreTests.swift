import DirnexCore
import Foundation
import Testing

@testable import Dirnex

/// A tree tab on an SMB server's list comes back as it was left: the shares open, the folders inside
/// them open, and the cursor on the same file (PLAN.md §M35).
///
/// Reported 2026-11-04: a tab left with `media/Movies` open and the cursor on a film came back with
/// only `home` and `media` open and the cursor on `home`. Everything under an expanded share is a
/// local path under its mount point, which is not under the tab's root, so none of it was written
/// down. A temporary folder stands in for the mount here, recorded through `SMBMounter`'s own seams,
/// so the listings below are real ones off the disk and nothing reaches NetFS.
@Suite("SMB tree restore", .serialized)
@MainActor
struct SMBTreeRestoreTests {
    private static let server = SMBLocation(host: "nas", username: "dirnex-test")
    private static var root: VFSPath { VFSPath(backend: .smbServer(server), path: "/") }
    private static var mediaRow: VFSPath { VFSPath(backend: .smbServer(server), path: "/media") }

    /// A folder laid out as the share's mount: `Movies/Crime.mkv` and `Movies/Hobbit.mkv`.
    private static func makeMount() throws -> URL {
        let mount = FileManager.default.temporaryDirectory
            .appendingPathComponent("SMBTreeRestore-\(UUID().uuidString)")
            .appendingPathComponent("media")
        let movies = mount.appendingPathComponent("Movies")
        try FileManager.default.createDirectory(at: movies, withIntermediateDirectories: true)
        for name in ["Crime.mkv", "Hobbit.mkv"] {
            try Data().write(to: movies.appendingPathComponent(name))
        }
        return mount
    }

    /// `media` recorded as mounted at `mount`, and the mount table told it is a network mount, for the
    /// length of `body`. Put back afterwards, so no other test sees a mount that never happened.
    private static func withShareMounted(at mount: URL, _ body: () async throws -> Void) async rethrows {
        let mounter = SMBMounter.shared
        let isNetworkMount = mounter.isNetworkMount
        mounter.isNetworkMount = { $0 == mount.path || isNetworkMount($0) }
        mounter.record(server.share(named: "media"), mountedAt: mount.path)
        defer {
            mounter.forget(mountedAt: mount.path)
            mounter.isNetworkMount = isNetworkMount
        }
        try await body()
    }

    private static func row(_ path: VFSPath, kind: FileEntry.Kind = .directory) -> FileEntry {
        FileEntry(
            path: path,
            name: path.lastComponent,
            kind: kind,
            byteSize: 0,
            modificationDate: FileEntry.unknownDate,
            creationDate: FileEntry.unknownDate,
            isHidden: false,
            permissions: 0o755,
            inode: 0
        )
    }

    /// A tree pane standing on the server's list, whose one row is the `media` share. Its backend is
    /// the local one, which is what lists the folders inside the mount, and it is not a composite, so
    /// no share row can reach NetFS.
    private static func treePane() -> PanelViewController {
        let pane = PanelViewController(
            backend: LocalBackend(),
            restoration: nil,
            defaultPath: root,
            restorationKey: nil
        )
        let listing = DirectoryListing(path: root, entries: [row(mediaRow)])
        pane.panel = Panel(model: DirectoryModel(listing: listing))
        pane.tabs[0].viewMode = .tree
        pane.panel.enterTreeMode()
        return pane
    }

    // MARK: - Writing it down

    @Test("folders and a cursor inside a mounted share are written through the share")
    func persistsThroughTheShare() async throws {
        let mount = try Self.makeMount()
        defer { try? FileManager.default.removeItem(at: mount.deletingLastPathComponent()) }
        try await Self.withShareMounted(at: mount) {
            let pane = Self.treePane()
            let movies = VFSPath.local(mount.appendingPathComponent("Movies").path)
            let film = movies.appending("Crime.mkv")
            pane.panel.expand(Self.mediaRow)
            pane.panel.setTreeChildListing(Self.mediaRow, entries: [Self.row(movies)])
            pane.panel.expand(movies)
            pane.panel.setTreeChildListing(movies, entries: [Self.row(film, kind: .file)])
            let index = try #require(pane.panel.displayedIndex(ofID: film))
            pane.panel.moveCursor(to: index)

            #expect(pane.persistedExpandedPaths(for: pane.tabs[0]) == ["media", "media/Movies"])
            #expect(pane.rootRelativePath(film, under: Self.root) == "media/Movies/Crime.mkv")
        }
    }

    @Test("with the share not mounted, a local path is under nothing and resolves to no row")
    func unmountedShareSpellsNothing() {
        let pane = Self.treePane()
        #expect(pane.rootRelativePath(.local("/Volumes/media/Movies"), under: Self.root) == nil)
        #expect(pane.resolveRootRelative("media/Movies", under: Self.root)
            == VFSPath(backend: .smbServer(Self.server), path: "/media/Movies"))
        #expect(pane.resolveRootRelative("media", under: Self.root) == Self.mediaRow)
    }

    // MARK: - Bringing it back

    @Test("a folder inside a share waits for the share, then opens and the cursor lands in it")
    func reopensInsideTheShareOnceMounted() async throws {
        let mount = try Self.makeMount()
        defer { try? FileManager.default.removeItem(at: mount.deletingLastPathComponent()) }
        let pane = Self.treePane()
        let tab = pane.tabs[0]
        tab.pendingCursorPath = "media/Movies/Hobbit.mkv"

        // A relaunch: nothing is mounted, so `media/Movies` cannot be named yet. The share row
        // opens; the folder inside it waits, counted as a listing still to come.
        #expect(pane.shareAwaitingMount("media/Movies", under: Self.root) == "media")
        tab.pendingRestoreTreeLoads = 1
        tab.pendingShareExpansions = ["media": ["media/Movies"]]
        pane.panel.expand(Self.mediaRow)

        try await Self.withShareMounted(at: mount) {
            // The share row's expansion has mounted it and listed its root.
            let movies = VFSPath.local(mount.appendingPathComponent("Movies").path)
            pane.panel.setTreeChildListing(Self.mediaRow, entries: [Self.row(movies)])

            pane.restoreExpansionsInsideShare(Self.mediaRow, inTab: 0)
            #expect(pane.panel.tree?.expanded.contains(movies) == true)
            #expect(tab.pendingShareExpansions.isEmpty)

            // `Movies` lists off the disk, and its landing anchors the cursor on the film.
            try await settleUntil { pane.panel.currentEntry?.name == "Hobbit.mkv" }
            #expect(pane.panel.currentEntry?.path == movies.appending("Hobbit.mkv"))
            #expect(tab.pendingCursorPath == nil)
            #expect(tab.pendingRestoreTreeLoads == 0)
        }
    }

    @Test("a share that does not mount gives up what waited inside it and closes the restore")
    func failedShareClosesTheRestore() async throws {
        let pane = Self.treePane()
        let tab = pane.tabs[0]
        tab.pendingExpandedPaths = ["media", "media/Movies"]
        tab.pendingCursorPath = "media/Movies/Hobbit.mkv"

        pane.restorePendingTreeExpansion()
        // The share row is opening; the folder inside it is waiting rather than opened as a share.
        #expect(pane.panel.tree?.expanded == [Self.mediaRow])
        #expect(tab.pendingShareExpansions == ["media": ["media/Movies"]])
        #expect(tab.pendingRestoreTreeLoads == 2)

        // This pane's backend cannot mount anything, so the share's expansion fails, and with it
        // everything that waited inside it: the window closes and the cursor stops waiting.
        try await settleUntil { tab.pendingRestoreTreeLoads == 0 }
        #expect(tab.pendingShareExpansions.isEmpty)
        #expect(tab.pendingCursorPath == nil)
    }

    @Test("a folder two levels into a share is not taken for a share of its own")
    func shareRowsAreOneLevelDeep() {
        #expect(Self.mediaRow.isSMBShareRow)
        #expect(!VFSPath(backend: .smbServer(Self.server), path: "/media/Movies").isSMBShareRow)
    }
}
