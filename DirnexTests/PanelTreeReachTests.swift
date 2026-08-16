import AppKit
import DirnexCore
import Foundation
import Testing

@testable import Dirnex

/// Where tree mode applies, and what a tree may watch once it applies there (PLAN.md §M15 Slice 4).
///
/// `canUseTreeMode` read `panel.path.backend == .local` until 2026-08-17. That gate was testing the
/// **pane's own path** where the real requirement is about each *row* — and the rows always could be
/// listed, because `DirectoryLoader.list` goes through `CompositeBackend`, which routes per path, and
/// `TreeProjection` recurses into each entry's own path rather than assuming it descends from the
/// root. So the restriction cost the feature everywhere but this Mac's own disk, and it did it in the
/// worst-behaved way available: a pane that was already a tree kept its tree across the navigation
/// (`Panel.setModel` re-roots rather than drops one), so View ▸ Tree View drew its checkmark from the
/// pane's real shape and its enablement from the gate — **ticked and gray**, with rows still drawing
/// disclosure triangles and no way to answer it. The command ships unbound, so the menu was the only
/// route; binding a shortcut would not have helped, since a disabled `NSMenuItem` swallows its own
/// key equivalent (docs/NOTES.md ▸ AppKit).
///
/// What the widening then makes reachable is a watcher over paths FSEvents cannot watch, which is why
/// half of this suite is about `treeWatchSources` rather than about the gate.
@MainActor
@Suite("Tree mode's reach")
struct PanelTreeReachTests {
    private enum Remote {
        static let sftp = VFSBackendID.sftp(
            SFTPLocation(host: "example.com", port: 22, username: "oleg")
        )
    }

    private static func pane(at path: VFSPath = .local(NSHomeDirectory())) -> PanelViewController {
        PanelViewController(
            backend: CompositeBackend(local: LocalBackend()),
            restoration: nil,
            defaultPath: path,
            restorationKey: nil
        )
    }

    /// A pane already in tree mode, the way the user's is when they click a sidebar row.
    private static func treePane(at path: VFSPath = .local(NSHomeDirectory())) -> PanelViewController {
        let pane = pane(at: path)
        pane.viewMode = .tree
        pane.applyViewMode()
        return pane
    }

    private static func treeItem() -> NSMenuItem {
        let item = NSMenuItem()
        item.action = #selector(PanelViewController.toggleTreeView(_:))
        return item
    }

    private static func folder(_ path: VFSPath) -> FileEntry {
        FileEntry(
            path: path,
            name: path.lastComponent,
            kind: .directory,
            byteSize: 0,
            modificationDate: Date(timeIntervalSince1970: 0),
            creationDate: Date(timeIntervalSince1970: 0),
            isHidden: false,
            permissions: 0o755,
            inode: 0
        )
    }

    // MARK: - The gate

    /// The merged listing is the one the user reported, and the one where a tree is least obvious:
    /// its root is synthetic and its rows are real directories scattered across containers.
    @Test("the merged iCloud listing can be a tree")
    func iCloudCanBeATree() {
        let pane = Self.treePane()
        pane.installResults([], as: pane.iCloudPresentation())

        #expect(pane.canUseTreeMode)
        #expect(pane.panel.isTree)
    }

    @Test("so can a remote directory, an archive and a results snapshot")
    func everywhereElseCanToo() {
        let places: [(String, VFSPath)] = [
            ("SFTP", VFSPath(backend: Remote.sftp, path: "/home/oleg")),
            ("an archive", VFSPath(backend: .archive(forArchiveAt: "/tmp/pkg.zip"), path: "/")),
            ("search results", VFSPath(backend: .search, path: "/Results")),
            ("the merged Trash", VFSPath(backend: .trash, path: "/Trash"))
        ]
        for (name, path) in places {
            let pane = Self.treePane(at: path)
            #expect(pane.canUseTreeMode, "\(name)")
            #expect(pane.validateMenuItem(Self.treeItem()), "View ▸ Tree View in \(name)")
        }
    }

    /// The dead end itself, kept as an invariant rather than as a case: a menu item that is checked
    /// and disabled is a setting the user cannot answer, wherever it happens.
    @Test("View ▸ Tree View is never both ticked and gray")
    func menuItemIsNeverCheckedAndDisabled() {
        let pane = Self.treePane()
        pane.installResults([], as: pane.iCloudPresentation())

        let item = Self.treeItem()
        let enabled = pane.validateMenuItem(item)
        #expect(!(item.state == .on && !enabled), "checked and gray: no way to switch it off")
        #expect(item.state == .on, "the pane really is a tree, so the box is ticked")
        #expect(enabled)
    }

    // MARK: - What a tree may watch

    /// The hazard the old gate was hiding. `listedDirectories` includes the tree's **root**, and for a
    /// merged listing that is `icloud:/iCloud Drive` — not a path FSEvents can watch. The filter has to
    /// test the path, not its capabilities: `CompositeBackend.capabilities(for:)` deliberately answers
    /// the *local* backend's full set for that container, `.watch` included.
    @Test("a tree over a merged root watches the real directories, never the synthetic one")
    func mergedRootIsNotWatched() {
        let pane = Self.treePane()
        let container = VFSPath.local(NSHomeDirectory())
            .appending("Library")
            .appending("Mobile Documents")
        pane.mergedSources = [container]
        pane.installResults(
            [Self.folder(container.appending("com~apple~Pages"))],
            as: pane.iCloudPresentation()
        )

        let sources = pane.treeWatchSources
        #expect(sources == [container])
        #expect(!sources.contains(where: { $0.backend != .local }))
    }

    @Test("a tree on a server watches nothing at all")
    func remoteTreeWatchesNothing() {
        let pane = Self.treePane(at: VFSPath(backend: Remote.sftp, path: "/home/oleg"))

        #expect(pane.treeWatchSources.isEmpty)

        // And the stream is torn down rather than left pointing at wherever the pane was before.
        pane.startWatchingTree(force: true)
        #expect(pane.watchedSources.isEmpty)
    }

    // MARK: - Narrowness

    /// The control that stops "watch nothing, ever" from passing the two above, and "flatten
    /// everywhere" from passing the gate tests: an ordinary local tree still watches its own
    /// directories and is still a tree.
    @Test("a local tree still watches its listed directories")
    func localTreeStillWatches() {
        let home = VFSPath.local(NSHomeDirectory())
        let pane = Self.treePane(at: home)
        pane.panel.setModel(DirectoryModel(listing: DirectoryListing(path: home, entries: [])))
        pane.applyViewMode()

        #expect(pane.panel.isTree)
        #expect(pane.treeWatchSources == [home])
    }
}
