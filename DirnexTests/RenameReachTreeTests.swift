import AppKit
import DirnexCore
import Foundation
import Testing

@testable import Dirnex

/// Renaming in a **tree**, which is the one shape where a pane's rows can belong to a different
/// backend — or a different directory — than the pane itself.
///
/// Its own suite because `RenameReachTests` answers a different question: it is a table of
/// *locations*, one row per place a pane can stand, and every row of a flat listing lives in the
/// pane's own directory. Here the pane is fixed and the **cursor** moves, which is the axis the
/// 2026-08-22 bug lived on: an S3 account pane draws buckets, which nothing renames, and an expanded
/// bucket draws prefixes on the `s3://` backend, which rename with a copy and a delete.
///
/// Every case moves the cursor within one pane and asserts the answer changes (or does not) with it.
/// A single-row test cannot see any of this — it would pass against a gate hard-wired to `panel.path`.
/// The account this suite's pane is connected to. File-private and named for this suite, because
/// `EditRouteTests` and `RenameReachTests` each keep their own — a shared one would have to be
/// internal, and `Remote` is already taken twice over.
private enum TreeFixture {
    static let bucket = S3Location(
        host: "s3.eu-north-1.amazonaws.com",
        bucket: "amzn-s3-df",
        region: "eu-north-1",
        accessKeyID: "AKIAEXAMPLE"
    )
}

@MainActor
@Suite("Rename's reach in a tree")
struct RenameReachTreeTests {
    private static func menuItem(_ action: Selector) -> NSMenuItem {
        let item = NSMenuItem()
        item.action = action
        return item
    }

    /// The pane in the screenshot: an S3 account, with a bucket expanded under it.
    ///
    /// An account pane rather than a local tree because a local tree cannot see this at all —
    /// `LocalBackend` answers for the root and for every row alike, so the two spellings agree
    /// however far they have drifted. The same reason `RenameReachTests` insists on a real
    /// `CompositeBackend`.
    private static func accountTreePane() -> PanelViewController {
        let composite = CompositeBackend(local: LocalBackend())
        composite.connectS3Account(account: TreeFixture.bucket.account, secretAccessKey: "secret")
        // Expanding a bucket row *connects* it — `S3AccountBackend` answers for its root and nothing
        // deeper — which is what puts the child rows on the bucket's own backend.
        composite.connectS3(location: TreeFixture.bucket, secretAccessKey: "secret")

        let accountRoot = VFSPath(backend: .s3Account(TreeFixture.bucket.account), path: "/")
        let bucketRow = accountRoot.appending(TreeFixture.bucket.bucket)
        let bucketRoot = VFSPath(backend: .s3(TreeFixture.bucket), path: "/")

        let pane = PanelViewController(
            backend: composite,
            restoration: nil,
            defaultPath: accountRoot,
            restorationKey: nil
        )
        var panel = Panel(model: DirectoryModel(listing: DirectoryListing(
            path: accountRoot,
            entries: [directory(TreeFixture.bucket.bucket, at: bucketRow)]
        )))
        panel.enterTreeMode()
        // The child rows keep their own `s3://` paths — the crossing, not a walk down from the
        // account (`PanelViewController+Tree` ▸ `s3BucketChildren`).
        panel.setTreeChildListing(bucketRow, entries: [
            directory("untitled folder", at: bucketRoot.appending("untitled folder"))
        ])
        panel.expand(bucketRow)
        pane.panel = panel
        return pane
    }

    private static func directory(_ name: String, at path: VFSPath) -> FileEntry {
        FileEntry(
            path: path,
            name: name,
            kind: .directory,
            byteSize: 0,
            modificationDate: FileEntry.unknownDate,
            creationDate: FileEntry.unknownDate,
            isHidden: false,
            permissions: 0o755,
            inode: 0
        )
    }

    /// Both rows of the same pane, in one test, and the contrast is the assertion: the *same* gate,
    /// on the *same* pane, has to answer differently depending only on which row the cursor is on.
    /// Row 0 is what keeps "follow the cursor" from quietly becoming "a tree can rename anything" —
    /// a bucket is refused because the account backend is still the one being asked about it.
    @Test("in an S3 account tree the gate follows the cursor into the bucket")
    func followsTheCursorAcrossBackends() {
        let pane = Self.accountTreePane()
        let renameItem = Self.menuItem(#selector(PanelViewController.renameSelection(_:)))
        let multiItem = Self.menuItem(#selector(PanelViewController.multiRenameSelection(_:)))

        // Row 0 — the bucket itself. S3 renames a bucket at no level, so this must stay refused.
        #expect(pane.panel.currentEntry?.name == TreeFixture.bucket.bucket)
        #expect(pane.canRenameHere == false)
        #expect(pane.validateMenuItem(renameItem) == false)
        #expect(pane.validateMenuItem(multiItem) == false)

        // Row 1 — a prefix inside the expanded bucket, on the bucket's own backend.
        pane.panel.moveCursor(to: 1)
        #expect(pane.panel.currentEntry?.name == "untitled folder")
        #expect(pane.canRenameHere == true)
        #expect(pane.validateMenuItem(renameItem) == true)
        #expect(pane.validateMenuItem(multiItem) == true)
    }

    /// The other half of "everywhere", one level down: a tree over a **search snapshot** draws rows
    /// from real directories, and those rows had been refused for a property of the container they
    /// were listed under.
    ///
    /// Both levels, because the interesting claim is that they now agree — the hit itself and a file
    /// inside a folder expanded beneath it are both ordinary files in ordinary directories, and the
    /// old gate refused them together for a reason that was true of neither.
    @Test("a tree over a search snapshot renames at every level")
    func virtualTreeRenamesAtEveryLevel() {
        let composite = CompositeBackend(local: LocalBackend())
        let results = VFSPath(backend: .search, path: "/Results")
        let hit = VFSPath.local("/Users/tester/Documents")
        let pane = PanelViewController(
            backend: composite,
            restoration: nil,
            defaultPath: results,
            restorationKey: nil
        )
        var panel = Panel(model: DirectoryModel(listing: DirectoryListing(
            path: results,
            entries: [Self.directory("Documents", at: hit)]
        )))
        panel.enterTreeMode()
        panel.setTreeChildListing(
            hit,
            entries: [Self.directory("notes", at: hit.appending("notes"))]
        )
        panel.expand(hit)
        pane.panel = panel

        #expect(pane.canRenameHere == true)
        pane.panel.moveCursor(to: 1)
        #expect(pane.panel.currentEntry?.name == "notes")
        #expect(pane.canRenameHere == true)
    }

    /// The narrowness control in the widening direction: an **archive** tree stays refused at every
    /// level, and by its own reason rather than by the retired listing flag — a browsed archive is
    /// `.read` through the VFS primitives, because its writes go through the rewrite path instead.
    @Test("an archive tree is still refused at every level")
    func archiveTreeStaysRefused() {
        let composite = CompositeBackend(local: LocalBackend())
        let root = VFSPath(backend: .archive(forArchiveAt: "/Users/tester/pkg.zip"), path: "/")
        let inner = root.appending("inner")
        let pane = PanelViewController(
            backend: composite,
            restoration: nil,
            defaultPath: root,
            restorationKey: nil
        )
        var panel = Panel(model: DirectoryModel(listing: DirectoryListing(
            path: root,
            entries: [Self.directory("inner", at: inner)]
        )))
        panel.enterTreeMode()
        panel.setTreeChildListing(
            inner,
            entries: [Self.directory("deep", at: inner.appending("deep"))]
        )
        panel.expand(inner)
        pane.panel = panel

        #expect(pane.canRenameHere == false)
        pane.panel.moveCursor(to: 1)
        #expect(pane.panel.currentEntry?.name == "deep")
        #expect(pane.canRenameHere == false)
    }
}
