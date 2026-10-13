import Foundation
import Testing

@testable import DirnexCore

/// A search snapshot after the pane deleted some of its hits, and after ⌘Z put some back.
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

    // MARK: - Removing

    @Test("the deleted rows go, and the rest keep their order")
    func removesDeletedRows() {
        let entries = ["a", "b", "c"].map { Self.hit($0) }
        let remaining = SearchSnapshot.removing([entries[1].path], from: entries)
        #expect(remaining.map(\.name) == ["a", "c"])
    }

    /// A row inside an expanded folder is not a hit; the tree's re-list of that folder handles it.
    @Test("a path the snapshot does not hold changes nothing")
    func ignoresUnknownPaths() {
        let entries = [Self.hit("a")]
        let remaining = SearchSnapshot.removing(
            [.local("/Users/tester/Documents/sub/deep")],
            from: entries
        )
        #expect(remaining == entries)
    }

    // MARK: - Reconciling

    @Test("a trashed hit that is back is shown again")
    func undoBringsTheRowBack() throws {
        let kept = Self.hit("kept")
        let trashed = Self.hit("trashed")
        let shown = try #require(SearchSnapshot.reconciled(
            [kept],
            trashed: [trashed],
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
            SearchSnapshot.reconciled([kept, trashed], trashed: [trashed], present: [])
        )
        #expect(shown.map(\.name) == ["kept"])
    }

    /// The common case — every refresh after the delete itself lands here — and the one whose
    /// answer must be "nothing to do", or every refresh would redraw identical rows.
    @Test("nothing changed answers nil")
    func steadyStateIsNil() {
        let kept = Self.hit("kept")
        let trashed = Self.hit("trashed")
        #expect(SearchSnapshot.reconciled([kept], trashed: [trashed], present: []) == nil)
        #expect(
            SearchSnapshot.reconciled([kept, trashed], trashed: [trashed], present: [trashed.path]) == nil
        )
        #expect(SearchSnapshot.reconciled([kept], trashed: [], present: []) == nil)
    }

    /// The narrowness control: only the hits the pane trashed are followed. A row deleted somewhere
    /// else stays, because a snapshot keeps the hits it was given.
    @Test("a row the pane did not trash is never dropped")
    func onlyTrashedHitsAreFollowed() {
        let untouched = Self.hit("untouched")
        #expect(
            SearchSnapshot.reconciled([untouched], trashed: [Self.hit("other")], present: []) == nil
        )
    }

    /// The same hit trashed, put back and trashed again is followed twice; it must still be one row.
    @Test("a hit followed twice comes back once")
    func duplicatesComeBackOnce() throws {
        let trashed = Self.hit("trashed")
        let shown = try #require(
            SearchSnapshot.reconciled([], trashed: [trashed, trashed], present: [trashed.path])
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
