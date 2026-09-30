import Foundation
import Testing

@testable import DirnexCore

/// The subtree shortcut a sync scan takes when a backend offers one (PLAN.md §M25 Slice 5c).
///
/// The claim under test is narrow and is the only reason the shortcut is safe to take: it changes
/// **where a directory's children come from** and nothing else. So every assertion here is either
/// "the rows are the same as the walk's" or "the listings did not happen" — and the pair is what
/// separates a shortcut that works from one that merely returns.
@Suite("DirectorySync — the subtree shortcut")
struct DirectorySyncSubtreeTests {
    /// Two roots holding the same three-level shape, with one difference planted at depth two.
    private func tree() throws -> TempTree {
        let tree = try TempTree()
        for side in ["L", "R"] {
            try tree.makeDir("\(side)/docs/api")
            try tree.writeFile("\(side)/top.txt", contents: "same")
            try tree.writeFile("\(side)/docs/guide.md", contents: "same")
        }
        try tree.writeFile("L/docs/api/ref.json", contents: "left")
        try tree.writeFile("R/docs/api/ref.json", contents: "a different length")
        return tree
    }

    private func compare(
        _ tree: TempTree,
        left: some VFSBackend,
        right: some VFSBackend
    ) throws -> [SyncEntry] {
        try DirectorySync.compare(
            left: tree.vfsPath("L"),
            right: tree.vfsPath("R"),
            leftBackend: left,
            rightBackend: right,
            comparison: .size
        )
    }

    @Test("a complete subtree answers the whole scan without listing a single directory")
    func shortcutReplacesEveryListing() throws {
        let tree = try tree()
        defer { tree.cleanup() }
        let shortcut = SubtreeBackend(isComplete: true)
        let walked = try compare(tree, left: LocalBackend(), right: LocalBackend())
        let viaShortcut = try compare(tree, left: shortcut, right: shortcut)

        #expect(viaShortcut == walked)
        #expect(viaShortcut.map(\.relativePath) == ["docs/api/ref.json"])
        // The whole saving: on a server each of these is a connection (59 ms measured on loopback).
        #expect(shortcut.listedPaths.isEmpty)
        #expect(shortcut.subtreeRequests == 2)
    }

    /// The hazard the shortcut brings with it. SFTP caps its answer at a row limit it chose and says
    /// so; a search may report a truncated result and a **sync may not**, because a mirror over a
    /// subtree that stopped early deletes the other side's matching files. Slower and right.
    @Test("an incomplete subtree is not used — the walk runs and the rows are whole")
    func incompleteSubtreeFallsBackToTheWalk() throws {
        let tree = try tree()
        defer { tree.cleanup() }
        let capped = SubtreeBackend(isComplete: false)
        let walked = try compare(tree, left: LocalBackend(), right: LocalBackend())
        let viaCapped = try compare(tree, left: capped, right: capped)

        #expect(viaCapped == walked)
        #expect(viaCapped.map(\.relativePath) == ["docs/api/ref.json"])
        #expect(!capped.listedPaths.isEmpty)
    }

    /// The narrowness control: "prefer the shortcut" must not have become "never list". A backend
    /// with no shortcut is the ordinary case and every existing comparison test rides on it.
    @Test("a backend with no shortcut still walks, one listing per directory pair")
    func noShortcutStillWalks() throws {
        let tree = try tree()
        defer { tree.cleanup() }
        let counting = SubtreeBackend(isComplete: true, offersShortcut: false)
        #expect(try compare(tree, left: counting, right: counting).map(\.relativePath)
            == ["docs/api/ref.json"])
        // L, L/docs, L/docs/api and the same three on the right.
        #expect(counting.listedPaths.count == 6)
        #expect(counting.subtreeRequests == 2)
    }

    /// The semantics the shortcut must not change, and the one a flat listing most easily would: a
    /// directory present on only one side is **one** row for its whole subtree, even though the
    /// prefetched listing is holding every file inside it.
    @Test("a one-sided directory is still a single row, not its contents")
    func oneSidedDirectoryStaysOneRow() throws {
        let tree = try TempTree()
        defer { tree.cleanup() }
        try tree.makeDir("R")
        try tree.makeDir("L/only/deeper")
        try tree.writeFile("L/only/a.txt", contents: "a")
        try tree.writeFile("L/only/deeper/b.txt", contents: "b")

        let shortcut = SubtreeBackend(isComplete: true)
        let results = try compare(tree, left: shortcut, right: shortcut)
        #expect(results.map(\.relativePath) == ["only"])
        #expect(results[0].status == .leftOnly)
        #expect(shortcut.listedPaths.isEmpty)
    }

    /// A prefetched side must not fall through to a listing for a directory its map has no key
    /// for — an empty folder is **empty**, not unknown, and listing it would put back exactly the
    /// per-directory round trip the gather paid once to avoid.
    @Test("an empty directory on a prefetched side costs no listing")
    func emptyDirectoryOnAPrefetchedSideCostsNothing() throws {
        let tree = try TempTree()
        defer { tree.cleanup() }
        try tree.makeDir("L/shared")
        try tree.makeDir("R/shared")
        try tree.writeFile("L/f.txt", contents: "x")

        let shortcut = SubtreeBackend(isComplete: true)
        let results = try compare(tree, left: shortcut, right: shortcut)
        #expect(results.map(\.relativePath) == ["f.txt"])
        #expect(shortcut.listedPaths.isEmpty)
    }
}

/// A local backend that can also hand over a whole subtree, standing in for SFTP's exec walk and
/// S3's delimiter-less listing. It counts both routes so a test can assert which one ran.
private final class SubtreeBackend: VFSBackend, @unchecked Sendable {
    private let inner = LocalBackend()
    private let lock = NSLock()
    private let isComplete: Bool
    private let offersShortcut: Bool
    private var listed: [VFSPath] = []
    private var subtrees = 0

    init(isComplete: Bool, offersShortcut: Bool = true) {
        self.isComplete = isComplete
        self.offersShortcut = offersShortcut
    }

    var listedPaths: [VFSPath] {
        lock.lock()
        defer { lock.unlock() }
        return listed
    }

    var subtreeRequests: Int {
        lock.lock()
        defer { lock.unlock() }
        return subtrees
    }

    var id: VFSBackendID { inner.id }
    var capabilities: VFSCapabilities { inner.capabilities }

    func listDirectory(at path: VFSPath) throws -> [FileEntry] {
        lock.lock()
        listed.append(path)
        lock.unlock()
        return try inner.listDirectory(at: path)
    }

    func stat(at path: VFSPath) throws -> FileEntry { try inner.stat(at: path) }

    func subtreeListing(at path: VFSPath, isCancelled: () -> Bool) throws -> VFSSubtreeListing? {
        lock.lock()
        subtrees += 1
        lock.unlock()
        guard offersShortcut else { return nil }
        var entries: [FileEntry] = []
        var queue = [path]
        while let directory = queue.popLast() {
            for entry in try inner.listDirectory(at: directory) {
                entries.append(entry)
                if entry.isDirectory { queue.append(entry.path) }
            }
        }
        // A capped answer is genuinely **short**, the way SFTP's row limit truncates a real one —
        // not the whole tree wearing a flag. That is what lets a control over the completeness
        // guard fail on the rows rather than merely on where they came from.
        guard isComplete else {
            return VFSSubtreeListing(entries: Array(entries.prefix(1)), isComplete: false)
        }
        return VFSSubtreeListing(entries: entries, isComplete: true)
    }
}
