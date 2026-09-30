import AppKit
import DirnexCore
import Foundation
import Testing

@testable import Dirnex

/// What a **tree refresh** can re-read (reported 2026-08-22: renaming a folder inside an expanded
/// bucket renamed it on the server and left the old name on screen).
///
/// `refreshTree` is the funnel every operation's "show me what I just did" goes through — the queued
/// rename an S3 prefix becomes reaches it via `refreshPanes`, and F7 and F8 reach it directly — and
/// it re-listed each of the tree's directories with `DirectoryLoader.list`. That is not how half of
/// them were produced: a **bucket row** hangs under an `s3account:` path, which
/// `S3AccountBackend.listDirectory` answers with `notFound` for anything but its root, so the re-read
/// failed into a `try?` and the row kept the entries it already had. Nothing logged, every request
/// succeeded, and the pane disagreed with the bucket for the rest of the session.
///
/// The fix routes the refresh through `treeChildEntries` — the same funnel the expansion used — so
/// the two cannot drift. These tests stand a real local directory in for the connected bucket root
/// (which is exactly what `s3BucketRoots` records: *where this row's children were listed from*), so
/// the whole path is exercised with no network and no credential.
@MainActor
@Suite("What a tree refresh can re-read")
struct TreeRefreshReachTests {
    private static let account = S3Location(
        host: "s3.dirnex-tree-refresh-fixture.invalid",
        bucket: "amzn-s3-df",
        region: "eu-north-1",
        accessKeyID: "AKIAFIXTUREEXAMPLE00"
    ).account

    private static var accountRoot: VFSPath {
        VFSPath(backend: .s3Account(account), path: "/")
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

    private static func pane(at path: VFSPath) -> PanelViewController {
        PanelViewController(
            backend: CompositeBackend(local: LocalBackend()),
            restoration: nil,
            defaultPath: path,
            restorationKey: nil
        )
    }

    /// A directory that is thrown away with the test.
    private static func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("dirnex-tree-refresh-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// Poll rather than spin the run loop: the refresh's listings are `await`ed, and a run-loop spin
    /// never lets a continuation land (docs/NOTES.md ▸ Testing).
    private static func waitForNames(
        _ pane: PanelViewController,
        under directory: VFSPath,
        toContain name: String
    ) async -> [String] {
        var names: [String] = []
        for _ in 0..<100 {
            names = (pane.panel.tree?.entries(in: directory) ?? []).map(\.name)
            if names.contains(name) { return names }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return names
    }

    // MARK: - The reported bug

    @Test("a refresh re-reads an expanded bucket's rows, not the account path they hang under")
    func refreshRereadsABucketRow() async throws {
        let bucketRoot = try Self.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: bucketRoot) }
        let pane = Self.pane(at: Self.accountRoot)
        let bucketRow = Self.accountRoot.appending("amzn-s3-df")

        var panel = Panel(model: DirectoryModel(listing: DirectoryListing(
            path: Self.accountRoot,
            entries: [Self.directory("amzn-s3-df", at: bucketRow)]
        )))
        panel.enterTreeMode()
        // What the expansion left behind: rows on the bucket's own backend, and the record of where
        // it listed them from. The rename has since happened on the server — so what is on disk is
        // the new name and what the tree holds is the old one, which is the reported state exactly.
        panel.setTreeChildListing(bucketRow, entries: [
            Self.directory("test3", at: VFSPath.local(bucketRoot.path).appending("test3"))
        ])
        panel.expand(bucketRow)
        pane.panel = panel
        pane.s3BucketRoots[bucketRow] = .local(bucketRoot.path)
        try FileManager.default.createDirectory(
            at: bucketRoot.appendingPathComponent("test4"),
            withIntermediateDirectories: true
        )

        pane.refreshTree()

        let names = await Self.waitForNames(pane, under: bucketRow, toContain: "test4")
        #expect(names == ["test4"], "the renamed folder replaces the row it was renamed from")
    }

    /// The narrowness control, and the one that matters more: routing the refresh through the
    /// expansion's funnel must not turn every directory into a bucket. An ordinary local child is
    /// still re-read by listing it.
    @Test("an ordinary expanded folder is still refreshed by listing it")
    func refreshRereadsALocalChild() async throws {
        let root = try Self.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let child = root.appendingPathComponent("child")
        try FileManager.default.createDirectory(at: child, withIntermediateDirectories: true)

        let rootPath = VFSPath.local(root.path)
        let childPath = rootPath.appending("child")
        let pane = Self.pane(at: rootPath)
        var panel = Panel(model: DirectoryModel(listing: DirectoryListing(
            path: rootPath,
            entries: [Self.directory("child", at: childPath)]
        )))
        panel.enterTreeMode()
        panel.setTreeChildListing(childPath, entries: [])
        panel.expand(childPath)
        pane.panel = panel
        try FileManager.default.createDirectory(
            at: child.appendingPathComponent("inside"),
            withIntermediateDirectories: true
        )

        pane.refreshTree()

        let names = await Self.waitForNames(pane, under: childPath, toContain: "inside")
        #expect(names == ["inside"])
    }

    // MARK: - What the refresh must not spend

    /// A refresh arrives at a bucket that is already open, and reconnecting to reach it would cost a
    /// second billed probe, a Keychain write and a re-registration — to land on the root already
    /// recorded. The observable is that it says nothing: this account has no secret filed, so a
    /// connect could only fail, and a failed one names the row it could not open.
    @Test("an already-open bucket is re-listed rather than re-connected")
    func openBucketIsNotReconnected() async throws {
        let bucketRoot = try Self.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: bucketRoot) }
        try FileManager.default.createDirectory(
            at: bucketRoot.appendingPathComponent("docs"),
            withIntermediateDirectories: true
        )
        let pane = Self.pane(at: Self.accountRoot)
        let bucketRow = Self.accountRoot.appending("amzn-s3-df")
        pane.s3BucketRoots[bucketRow] = .local(bucketRoot.path)

        let entries = await pane.s3BucketChildren(at: bucketRow)

        #expect(entries?.map(\.name) == ["docs"])
        #expect(pane.transientStatus == nil, "nothing was connected, so nothing could fail")
    }

    /// The other half: a bucket with no record still crosses. Without this, "reuse what we have"
    /// would quietly become "never connect", and a bucket would only ever open once per launch —
    /// here it stops at the Keychain, which is as far as a fixture account can get.
    @Test("a bucket with no recorded root still goes through the connect")
    func unrecordedBucketStillConnects() async {
        let pane = Self.pane(at: Self.accountRoot)
        let bucketRow = Self.accountRoot.appending("amzn-s3-df")

        let entries = await pane.s3BucketChildren(at: bucketRow)

        #expect(entries == nil)
        #expect(pane.transientStatus?.contains("amzn-s3-df") == true)
    }
}
