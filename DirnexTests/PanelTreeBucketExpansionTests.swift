import AppKit
import DirnexCore
import Foundation
import Testing

@testable import Dirnex

/// Expanding a **bucket row** in an S3 account pane's tree (PLAN.md §M21 Slice 9, widened 2026-08-19).
///
/// A bucket's children are not a listing. `S3AccountBackend` answers for its root and nothing deeper
/// — everything below a bucket is the `S3Backend` that already ships — so `DirectoryLoader.list` on
/// `s3account:/<bucket>` throws `notFound`, which the tree's lazy load swallows: the row stayed
/// expanded, empty and silent, with a disclosure triangle promising children nothing would deliver.
/// The fix routes that one case through the same connect Enter uses, so the region correction and the
/// path-style retry apply to `→` as well.
///
/// What can be pinned without a network is the **routing** — that a bucket row goes to the connect
/// and a folder does not — plus the two things the crossing changed underneath: the children carry
/// another backend's paths, so `←` can no longer find its parent row by path arithmetic.
@MainActor
@Suite("Expanding a bucket in a tree")
struct PanelTreeBucketExpansionTests {
    /// An account nothing can have filed a secret for, so `s3BucketChildren` stops at the Keychain
    /// and no `curl` is ever spawned. The route it takes to get there is the whole assertion.
    private static let account = S3Location(
        host: "s3.dirnex-tree-expansion-fixture.invalid",
        bucket: "unused",
        region: "eu-north-1",
        accessKeyID: "AKIAFIXTUREEXAMPLE00",
        addressing: .virtualHost,
        usesTLS: true
    ).account

    private static var accountRoot: VFSPath {
        VFSPath(backend: .s3Account(account), path: "/")
    }

    private static func pane(at path: VFSPath) -> PanelViewController {
        let pane = PanelViewController(
            backend: CompositeBackend(local: LocalBackend()),
            restoration: nil,
            defaultPath: path,
            restorationKey: nil
        )
        pane.viewMode = .tree
        pane.applyViewMode()
        return pane
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

    /// Seed a tree's root level the way a landed listing does.
    private static func seed(_ pane: PanelViewController, _ entries: [FileEntry]) {
        pane.panel.setModel(
            DirectoryModel(listing: DirectoryListing(path: pane.panel.path, entries: entries))
        )
        pane.applyViewMode()
    }

    /// Poll rather than spin the run loop: the expansion's work is an `await`, and a run-loop spin
    /// never lets a continuation land (docs/NOTES.md ▸ Testing).
    private static func waitForStatus(_ pane: PanelViewController) async -> String? {
        for _ in 0..<100 {
            if let status = pane.transientStatus { return status }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return pane.transientStatus
    }

    // MARK: - Routing

    /// The forward itself. A bucket row cannot be listed, so reaching the bucket-opening path at all
    /// is what is being measured — and the observable is that it *reports* by name, which only the
    /// bucket route does.
    @Test("expanding a bucket row goes through the bucket connect, not through a listing")
    func bucketRowRoutesToTheConnect() async {
        let pane = Self.pane(at: Self.accountRoot)
        let bucket = Self.accountRoot.appending("amzn-s3-df")
        Self.seed(pane, [Self.folder(bucket)])

        pane.toggleTreeExpansion(for: bucket)

        let status = await Self.waitForStatus(pane)
        #expect(status?.contains("amzn-s3-df") == true, "the row that could not be opened is named")
    }

    /// The narrowness control, and the one that matters more: answering for everything would send
    /// every ordinary folder down a connect it has no business making. An unreadable local folder
    /// stays childless and silent, exactly as it did before.
    @Test("an ordinary folder row is still a plain listing")
    func localRowIsUntouched() async {
        let root = VFSPath.local(NSTemporaryDirectory())
        let pane = Self.pane(at: root)
        let missing = root.appending("dirnex-tree-expansion-fixture-\(UUID().uuidString)")
        Self.seed(pane, [Self.folder(missing)])

        pane.toggleTreeExpansion(for: missing)

        // Give the load the same window the bucket case gets before concluding it said nothing.
        try? await Task.sleep(for: .milliseconds(400))
        #expect(pane.transientStatus == nil)
        #expect(pane.panel.tree?.isExpanded(missing) == true)
    }

    /// Two edges of the bucket route that need no network and would otherwise be reached by a
    /// `curl`: the account's own root is not a bucket, and neither is anything on another backend.
    @Test("the account root and a non-account path are not buckets")
    func onlyABucketRowIsABucket() async {
        let pane = Self.pane(at: Self.accountRoot)

        #expect(await pane.s3BucketChildren(at: Self.accountRoot) == nil)
        #expect(await pane.s3BucketChildren(at: .local(NSHomeDirectory())) == nil)
        #expect(pane.transientStatus == nil, "neither is a failure worth a sentence")
    }

    // MARK: - ⏎ inside an expanded bucket

    /// The row is the subject, not the pane — reported 2026-08-22.
    ///
    /// With a bucket expanded in an account pane, its contents are drawn beneath it on the `s3://`
    /// backend. ⏎ asked `panel.path.backend.isS3Account`, which is the *pane*, so every folder
    /// inside every expanded bucket was treated as a bucket row: entering `test2` inside
    /// `amzn-s3-df` asked the service to connect to a bucket called `test2` and reported that the
    /// key isn't allowed to list it — a refusal about a bucket that does not exist, over a folder
    /// the pane was already showing the contents of.
    ///
    /// The decision is asserted rather than the gesture: acting on it ends in a connect whose
    /// failure raises an alert, and an alert with no window blocks the whole run.
    @Test("⏎ on a folder inside an expanded bucket is not a bucket connect")
    func folderInsideABucketIsNotABucketRow() {
        let pane = Self.pane(at: Self.accountRoot)
        let bucket = Self.accountRoot.appending("amzn-s3-df")
        Self.seed(pane, [Self.folder(bucket)])

        let objects = VFSPath(
            backend: .s3(Self.account.bucketLocation(named: "amzn-s3-df")),
            path: "/"
        )
        let folder = Self.folder(objects.appending("test2"))
        pane.panel.expand(bucket)
        pane.panel.setTreeChildListing(bucket, entries: [folder])
        pane.panel.moveCursor(to: 1)

        let entry = pane.panel.currentEntry
        #expect(entry?.path == folder.path, "the cursor is on the row inside the bucket")
        #expect(pane.s3BucketToEnter(for: folder) == nil, "an object folder is not a bucket")
    }

    /// The narrowness control, and the half that keeps the fix from becoming "nothing is a bucket":
    /// the bucket row itself still crosses, from the same pane in the same tree.
    @Test("⏎ on the bucket row itself is still a bucket connect")
    func bucketRowIsStillABucketRow() {
        let pane = Self.pane(at: Self.accountRoot)
        let bucket = Self.accountRoot.appending("amzn-s3-df")
        let row = Self.folder(bucket)
        Self.seed(pane, [row])

        #expect(pane.s3BucketToEnter(for: row) == bucket)
    }

    // MARK: - What the crossing changed

    /// `←` used to climb by `entry.path.parent`, which is the same answer everywhere a child's path
    /// descends from its parent's — and no answer at all where it does not. A bucket's contents live
    /// on the bucket's backend, so the parent of `s3://…/docs` is `s3://…/`, while the row above it
    /// is `s3account:/amzn-s3-df`. Depth is what the tree actually draws, so it cannot disagree.
    @Test("← steps out of a bucket's contents onto the bucket row")
    func stepOutCrossesTheBackendBoundary() {
        let pane = Self.pane(at: Self.accountRoot)
        let bucket = Self.accountRoot.appending("amzn-s3-df")
        Self.seed(pane, [Self.folder(bucket)])

        let objects = VFSPath(
            backend: .s3(Self.account.bucketLocation(named: "amzn-s3-df")),
            path: "/"
        )
        pane.panel.expand(bucket)
        pane.panel.setTreeChildListing(bucket, entries: [Self.folder(objects.appending("docs"))])

        let child = pane.panel.tree?.index(ofID: objects.appending("docs"))
        #expect(child == 1)
        pane.panel.moveCursor(to: 1)

        _ = pane.fileTableCollapseOrStepOut(pane.tableView)

        #expect(pane.panel.cursor == 0, "the cursor lands on the bucket row above it")
        #expect(pane.panel.currentEntry?.path == bucket)
    }
}
