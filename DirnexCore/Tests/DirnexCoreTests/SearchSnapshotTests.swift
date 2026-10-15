import Foundation
import Testing

@testable import DirnexCore

/// A search snapshot after the app deleted or moved some of its hits, and after ⌘Z put some back.
@Suite("Search snapshot")
struct SearchSnapshotTests {
    private static func hit(_ name: String, in directory: String = "/Users/tester/Documents") -> FileEntry {
        FileEntry(
            path: .local("\(directory)/\(name)"),
            name: name,
            kind: .file,
            byteSize: 128,
            modificationDate: Date(timeIntervalSince1970: 1_000_000),
            creationDate: Date(timeIntervalSince1970: 900_000),
            isHidden: false,
            permissions: 0o644,
            inode: 7
        )
    }

    private static let documents = VFSPath.local("/Users/tester/Documents")
    private static let elsewhere = VFSPath.local("/Users/tester/Desktop")

    // MARK: - Applying

    @Test("a deleted row goes, and the rest keep their order")
    func removesDeletedRows() throws {
        let entries = ["a", "b", "c"].map { Self.hit($0) }
        let applied = try #require(SearchSnapshot.applying([.removed(entries[1].path)], to: entries))
        #expect(applied.entries.map(\.name) == ["a", "c"])
        #expect(applied.departed == [entries[1]])
    }

    /// F6: the file is no longer where the search found it, so neither is its row.
    @Test("a hit moved out of its folder leaves")
    func movedOutLeaves() throws {
        let entries = [Self.hit("a"), Self.hit("b")]
        let applied = try #require(SearchSnapshot.applying(
            [.moved(entries[0].path, to: Self.elsewhere.appending("a"))],
            to: entries
        ))
        #expect(applied.entries.map(\.name) == ["b"])
        #expect(applied.departed == [entries[0]])
    }

    /// A queued rename is a move that lands in the hit's own folder. Dropping it would lose a file
    /// that is still exactly where it was found.
    @Test("a hit moved within its own folder is renamed, not dropped")
    func movedInPlaceIsRenamed() throws {
        let entries = [Self.hit("old")]
        let applied = try #require(SearchSnapshot.applying(
            [.moved(entries[0].path, to: Self.documents.appending("new"))],
            to: entries
        ))
        #expect(applied.entries.map(\.name) == ["new"])
        #expect(applied.entries.map(\.path) == [Self.documents.appending("new")])
        #expect(applied.departed.isEmpty)
    }

    /// Same folder *path* on another backend is somewhere else: a move from this Mac to a server's
    /// `/Users/tester/Documents` is not a rename.
    @Test("a hit moved to the same path on another backend leaves")
    func otherBackendIsNotARename() throws {
        let entries = [Self.hit("a")]
        let server = VFSPath(
            backend: .sftp(SFTPLocation(host: "box", username: "tester")),
            path: "/Users/tester/Documents/a"
        )
        let applied = try #require(
            SearchSnapshot.applying([.moved(entries[0].path, to: server)], to: entries)
        )
        #expect(applied.entries.isEmpty)
        #expect(applied.departed == entries)
    }

    /// A row inside an expanded folder is not a hit; the tree's re-list of that folder handles it.
    @Test("a path the snapshot does not hold changes nothing")
    func ignoresUnknownPaths() {
        let entries = [Self.hit("a")]
        let deep = Self.documents.appending("sub").appending("deep")
        #expect(SearchSnapshot.applying([.removed(deep)], to: entries) == nil)
        #expect(
            SearchSnapshot.applying(
                [.moved(deep, to: Self.elsewhere.appending("deep"))],
                to: entries
            ) == nil
        )
        #expect(SearchSnapshot.applying([], to: entries) == nil)
    }

    // MARK: - What a job changed

    private static func report(_ outcomes: [OperationItemOutcome]) -> OperationReport {
        OperationReport(
            completedItems: outcomes.count,
            completedBytes: 0,
            skipped: [],
            failures: [],
            wasCancelled: false,
            outcomes: outcomes
        )
    }

    /// Everything a move moved, and nothing it skipped.
    @Test("a move reports what it relocated, and not what it skipped")
    func moveReportsItsRelocations() {
        let moved = Self.documents.appending("a")
        let skipped = Self.documents.appending("b")
        let report = Self.report([
            OperationItemOutcome(
                source: moved,
                landedAt: Self.elsewhere.appending("a"),
                replacedExisting: false
            ),
            OperationItemOutcome(source: skipped, landedAt: nil, replacedExisting: false)
        ])
        #expect(
            SearchSnapshot.changes(made: report, by: .move) == [
                .moved(moved, to: Self.elsewhere.appending("a"))
            ]
        )
    }

    /// The narrowness control: a copy leaves every source where it was.
    @Test("a copy changes no hit")
    func copyChangesNothing() {
        let report = Self.report([OperationItemOutcome(
            source: Self.documents.appending("a"),
            landedAt: Self.elsewhere.appending("a"),
            replacedExisting: false
        )])
        #expect(SearchSnapshot.changes(made: report, by: .copy).isEmpty)
    }

    /// Overwriting a file at the destination still took the hit away from where it was found.
    @Test("a move that replaced a file at its destination still moved the hit")
    func replacingMoveStillMoved() {
        let source = Self.documents.appending("a")
        let report = Self.report([
            OperationItemOutcome(
                source: source,
                landedAt: Self.elsewhere.appending("a"),
                replacedExisting: true
            )
        ])
        #expect(
            SearchSnapshot.changes(made: report, by: .move) == [
                .moved(source, to: Self.elsewhere.appending("a"))
            ]
        )
    }

    /// The same rule against the real engine rather than a hand-built report: of two hits moved
    /// into a folder that already holds one of their names, the skipped one is still on disk and
    /// must keep its row, while the other leaves.
    @Test("against the engine, a skipped hit stays and the moved one leaves")
    func engineSkippedHitStays() throws {
        let tree = try TempTree()
        defer { tree.cleanup() }
        try tree.writeFile("a.txt", contents: "a")
        try tree.writeFile("b.txt", contents: "b")
        try tree.makeDir("dest")
        try tree.writeFile("dest/b.txt", contents: "already here")
        let backend = LocalBackend()
        let hits = try ["a.txt", "b.txt"].map { try backend.stat(at: tree.vfsPath($0)) }

        let report = CopyEngine.run(
            FileOperation(kind: .move, sources: hits, destinationDirectory: tree.vfsPath("dest")),
            using: backend,
            conflictPolicy: .skip
        )
        let applied = try #require(SearchSnapshot.applying(
            SearchSnapshot.changes(made: report, by: .move),
            to: hits
        ))

        #expect(applied.entries.map(\.name) == ["b.txt"])
        #expect(applied.departed.map(\.name) == ["a.txt"])
        #expect(FileManager.default.fileExists(atPath: tree.path("b.txt")))
    }

    // MARK: - Reconciling

    @Test("a trashed hit that is back is shown again")
    func undoBringsTheRowBack() throws {
        let kept = Self.hit("kept")
        let trashed = Self.hit("trashed")
        let shown = try #require(SearchSnapshot.reconciled(
            [kept],
            departed: [trashed],
            present: [trashed.path]
        ))
        #expect(Set(shown.map(\.name)) == ["kept", "trashed"])
    }

    /// Redo, and any other way the item leaves again.
    @Test("a trashed hit that is gone again is dropped again")
    func redoDropsItAgain() throws {
        let kept = Self.hit("kept")
        let trashed = Self.hit("trashed")
        let shown = try #require(
            SearchSnapshot.reconciled([kept, trashed], departed: [trashed], present: [])
        )
        #expect(shown.map(\.name) == ["kept"])
    }

    /// The common case — every refresh after the delete itself lands here — and the one whose
    /// answer must be "nothing to do", or every refresh would redraw identical rows.
    @Test("nothing changed answers nil")
    func steadyStateIsNil() {
        let kept = Self.hit("kept")
        let trashed = Self.hit("trashed")
        #expect(SearchSnapshot.reconciled([kept], departed: [trashed], present: []) == nil)
        #expect(
            SearchSnapshot.reconciled([kept, trashed], departed: [trashed], present: [trashed.path]) == nil
        )
        #expect(SearchSnapshot.reconciled([kept], departed: [], present: []) == nil)
    }

    /// The narrowness control: only the hits that departed are followed. A row deleted somewhere
    /// else stays, because a snapshot keeps the hits it was given.
    @Test("a row that did not depart is never dropped")
    func onlyDepartedHitsAreFollowed() {
        let untouched = Self.hit("untouched")
        #expect(
            SearchSnapshot.reconciled([untouched], departed: [Self.hit("other")], present: []) == nil
        )
    }

    /// The same hit trashed, put back and trashed again is followed twice; it must still be one row.
    @Test("a hit followed twice comes back once")
    func duplicatesComeBackOnce() throws {
        let trashed = Self.hit("trashed")
        let shown = try #require(
            SearchSnapshot.reconciled([], departed: [trashed, trashed], present: [trashed.path])
        )
        #expect(shown.map(\.name) == ["trashed"])
    }

    // MARK: - Present

    /// Against the real disk, including the case `fileExists` gets wrong: a symlink whose target is
    /// gone is still there to be shown.
    @Test("present is asked of the item, not of what a link points to")
    func presentDoesNotFollowLinks() throws {
        let root = NSTemporaryDirectory() + "dirnex-snapshot-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: root) }
        let file = root + "/file.txt"
        let dangling = root + "/dangling"
        try Data("x".utf8).write(to: URL(fileURLWithPath: file))
        try FileManager.default.createSymbolicLink(
            atPath: dangling,
            withDestinationPath: root + "/nowhere"
        )

        let present = SearchSnapshot.present(
            [.local(file), .local(dangling), .local(root + "/missing.txt")],
            using: LocalBackend()
        )

        #expect(present == [.local(file), .local(dangling)])
    }
}
