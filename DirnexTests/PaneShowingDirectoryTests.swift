import AppKit
import DirnexCore
import Foundation
import Testing

@testable import Dirnex

/// Which pane a finished piece of work should re-list (reported 2026-08-22).
///
/// An edited S3 object uploaded back to the server perfectly and the row went on drawing `Zero KB`
/// with the old date. The write-back re-lists "the pane standing in the object's directory", and it
/// asked `pane.panel.path == directory` — the same sentence as this one in a flat list, and not in a
/// tree, which draws several directories at once. With a bucket expanded in an S3 **account** pane
/// the object's parent is two levels below the path that was compared, so neither pane matched and
/// nothing refreshed.
///
/// The subject is the **rows**, not the tree's listing keys, and that is the half a plainer fix
/// misses: `TreeProjection` files an expanded level under the row that was expanded, so a bucket's
/// children sit under `s3account:/<bucket>` while every row inside carries `s3://…`. Matching the
/// keys would still have answered no. Each test names the old predicate beside the new one, so what
/// is pinned is the difference rather than the answer.
@MainActor
@Suite("Which pane is showing a directory")
struct PaneShowingDirectoryTests {
    private static let account = S3Location(
        host: "s3.dirnex-showing-fixture.invalid",
        bucket: "unused",
        region: "eu-north-1",
        accessKeyID: "AKIAFIXTUREEXAMPLE00",
        addressing: .virtualHost,
        usesTLS: true
    ).account

    private static var accountRoot: VFSPath {
        VFSPath(backend: .s3Account(account), path: "/")
    }

    private static func bucketRoot(_ name: String) -> VFSPath {
        VFSPath(backend: .s3(account.bucketLocation(named: name)), path: "/")
    }

    private static func pane(at path: VFSPath, tree: Bool) -> PanelViewController {
        let pane = PanelViewController(
            backend: CompositeBackend(local: LocalBackend()),
            restoration: nil,
            defaultPath: path,
            restorationKey: nil
        )
        if tree {
            pane.viewMode = .tree
            pane.applyViewMode()
        }
        return pane
    }

    private static func entry(_ path: VFSPath, kind: FileEntry.Kind) -> FileEntry {
        FileEntry(
            path: path,
            name: path.lastComponent,
            kind: kind,
            byteSize: 0,
            modificationDate: Date(timeIntervalSince1970: 0),
            creationDate: Date(timeIntervalSince1970: 0),
            isHidden: false,
            permissions: kind == .directory ? 0o755 : 0o644,
            inode: 0
        )
    }

    private static func seed(_ pane: PanelViewController, _ entries: [FileEntry]) {
        pane.panel.setModel(
            DirectoryModel(listing: DirectoryListing(path: pane.panel.path, entries: entries))
        )
        pane.applyViewMode()
    }

    /// The reported shape, built exactly as the screenshot: an account pane in tree mode with one
    /// bucket expanded and the edited object drawn inside it.
    @Test("an expanded bucket's own root is showing, though the pane stands on the account")
    func expandedBucketIsShowing() {
        let pane = Self.pane(at: Self.accountRoot, tree: true)
        let bucketRow = Self.accountRoot.appending("amzn-s3-df")
        Self.seed(pane, [Self.entry(bucketRow, kind: .directory)])
        let objects = Self.bucketRoot("amzn-s3-df")
        pane.panel.expand(bucketRow)
        pane.panel.setTreeChildListing(
            bucketRow, entries: [Self.entry(objects.appending("test2.txt"), kind: .file)]
        )

        #expect(pane.isShowing(objects))
        // What the write-back used to ask, and why it never refreshed: neither the pane's own path
        // nor the key the expanded level is filed under is the directory the object lives in.
        #expect(pane.panel.path != objects)
        #expect(pane.panel.tree?.listedDirectories.contains(objects) == false)
    }

    /// The narrowness control: a pane is not showing a directory merely because it is on the same
    /// server. Without it, "everything is showing" would pass the test above.
    @Test("another bucket on the same account is not showing")
    func aSiblingBucketIsNotShowing() {
        let pane = Self.pane(at: Self.accountRoot, tree: true)
        let bucketRow = Self.accountRoot.appending("amzn-s3-df")
        Self.seed(pane, [Self.entry(bucketRow, kind: .directory)])
        let objects = Self.bucketRoot("amzn-s3-df")
        pane.panel.expand(bucketRow)
        pane.panel.setTreeChildListing(
            bucketRow, entries: [Self.entry(objects.appending("test2.txt"), kind: .file)]
        )

        #expect(!pane.isShowing(Self.bucketRoot("other-bucket")))
        #expect(!pane.isShowing(objects.appending("sub")))
        #expect(!pane.isShowing(.local(NSHomeDirectory())))
    }

    /// A folder expanded inside an ordinary local tree — the same claim without a backend crossing,
    /// so the answer cannot be resting on anything S3-specific.
    @Test("an expanded folder in a local tree is showing")
    func expandedLocalFolderIsShowing() {
        let root = VFSPath.local("/Users/tester/Documents")
        let pane = Self.pane(at: root, tree: true)
        let folder = root.appending("reports")
        Self.seed(pane, [Self.entry(folder, kind: .directory)])
        pane.panel.expand(folder)
        pane.panel.setTreeChildListing(
            folder, entries: [Self.entry(folder.appending("q3.txt"), kind: .file)]
        )

        #expect(pane.isShowing(root))
        #expect(pane.isShowing(folder))
        #expect(!pane.isShowing(root.appending("invoices")))
    }

    /// The pane's own path stays in whatever the rows say, because an **empty** directory has no row
    /// to derive it from — and that is exactly where a create lands. A rows-only answer would leave
    /// a pane showing an empty folder un-refreshed by the work that fills it.
    @Test("an empty pane is still showing its own directory")
    func emptyPaneShowsItsOwnDirectory() {
        let root = VFSPath.local("/Users/tester/Documents")
        let pane = Self.pane(at: root, tree: false)
        Self.seed(pane, [])

        #expect(pane.isShowing(root))
        #expect(!pane.isShowing(root.appending("sub")))
    }
}
