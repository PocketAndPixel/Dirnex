import Foundation
import Testing

@testable import DirnexCore

/// The walk that answers ⌥F7 where there is no index (PLAN.md §M22 Slice 1).
///
/// Driven by a fake backend serving a tree from a dictionary rather than by `LocalBackend` over a
/// temp directory, for one reason that decides the suite: what is under test is the *order and cost*
/// of the listings — breadth-first, budgeted, one request each — and only a backend that records
/// what it was asked can see any of that. A real filesystem would prove the matcher works and
/// nothing else.
@Suite("Subtree search")
struct SubtreeSearchTests {
    // MARK: - Fixture

    /// A tree with a match at depth 1 and another at depth 3, so a walk's *order* is observable.
    ///
    ///     /root
    ///       a/            report-a.txt
    ///       b/            notes.txt
    ///         deep/       report-deep.txt
    ///           deeper/   report-deeper.txt
    ///       report-top.txt
    private func tree() -> FakeTreeBackend {
        FakeTreeBackend(directories: [
            "/root": [.dir("a"), .dir("b"), .file("report-top.txt", size: 10)],
            "/root/a": [.file("report-a.txt", size: 100)],
            "/root/b": [.dir("deep"), .file("notes.txt", size: 1)],
            "/root/b/deep": [.dir("deeper"), .file("report-deep.txt", size: 5000)],
            "/root/b/deep/deeper": [.file("report-deeper.txt", size: 20)]
        ])
    }

    private func predicate(_ query: FileQuery) throws -> SearchPredicate {
        try SearchPredicate(query, answering: .listed)
    }

    // MARK: - Finding things

    @Test("every match at every depth comes back")
    func findsEverywhere() throws {
        let results = try SubtreeSearch.find(
            under: .local("/root"),
            using: tree(),
            matching: predicate(FileQuery(nameContains: "report"))
        )
        #expect(
            Set(results.hits.map(\.name))
                == ["report-top.txt", "report-a.txt", "report-deep.txt", "report-deeper.txt"]
        )
        #expect(results.completion == .complete)
        #expect(results.directoriesListed == 5)
    }

    /// The folder being searched *in* is not one of its own hits — it is the question, not an
    /// answer, and in a "This Folder" search it would match constantly.
    @Test("the root is never its own hit")
    func rootIsExcluded() throws {
        let results = try SubtreeSearch.find(
            under: .local("/root"),
            using: tree(),
            matching: predicate(FileQuery(nameContains: "root"))
        )
        #expect(results.hits.isEmpty)
    }

    // MARK: - Order, which only matters when the walk is cut short

    /// Breadth-first is the whole reason a bounded search is worth showing: cut off, it has covered
    /// the shallow tree rather than one deep branch. Asserted on the *listing order* the backend
    /// recorded, since that is the property — the hits themselves get sorted by the pane.
    @Test("directories are listed breadth-first")
    func breadthFirst() throws {
        let backend = tree()
        _ = try SubtreeSearch.find(
            under: .local("/root"),
            using: backend,
            matching: predicate(FileQuery(nameContains: "nothing-matches-this"))
        )
        #expect(
            backend.listed.map(\.path)
                == ["/root", "/root/a", "/root/b", "/root/b/deep", "/root/b/deep/deeper"]
        )
    }

    // MARK: - Stopping

    @Test("a budget stops the walk and says so, keeping what it found")
    func budgetExceeded() throws {
        let backend = tree()
        let results = try SubtreeSearch.find(
            under: .local("/root"),
            using: backend,
            matching: predicate(FileQuery(nameContains: "report")),
            budget: DirectorySizeBudget(directoryLimit: 2)
        )
        #expect(results.completion == .budgetExceeded)
        #expect(results.directoriesListed == 2)
        // The half a count cannot see: the limit stopped the walk from *making* the third request,
        // rather than making it and then giving up. On a billed backend those differ, and the one
        // that matters is what was spent.
        #expect(backend.listed.count == 2)
        // Partial hits are still real hits, which is why they are returned rather than thrown away.
        #expect(results.hits.map(\.name) == ["report-top.txt", "report-a.txt"])
    }

    @Test("the result limit truncates rather than failing")
    func truncates() throws {
        let results = try SubtreeSearch.find(
            under: .local("/root"),
            using: tree(),
            matching: predicate(FileQuery(nameContains: "report")),
            limit: 2
        )
        #expect(results.completion == .truncated)
        #expect(results.hits.count == 2)
    }

    /// Stop means "that's enough, show me what you have" — so a stopped walk keeps its hits, unlike
    /// a cancelled size walk, which has nothing honest to report. Driven with a flag that flips
    /// after the first listing, since stopping *before* anything ran would pass against a version
    /// that discarded everything.
    @Test("a stopped walk keeps what it found")
    func stoppingKeepsHits() throws {
        var listedOnce = false
        let results = try SubtreeSearch.find(
            under: .local("/root"),
            using: tree(),
            matching: predicate(FileQuery(nameContains: "report")),
            isCancelled: { listedOnce },
            onProgress: { _ in listedOnce = true }
        )
        #expect(results.completion == .stopped)
        #expect(results.hits.map(\.name) == ["report-top.txt"])
        #expect(results.directoriesListed == 1)
    }

    @Test("stopping before anything is listed simply finds nothing")
    func stoppingImmediately() throws {
        let results = try SubtreeSearch.find(
            under: .local("/root"),
            using: tree(),
            matching: predicate(FileQuery(nameContains: "report")),
            isCancelled: { true }
        )
        #expect(results.completion == .stopped)
        #expect(results.hits.isEmpty)
    }

    /// A flat backend cannot return partway through, so it says the same thing by throwing —
    /// and the caller must not be able to tell the two routes apart.
    @Test("a shortcut that is cancelled reports a stop, not an error")
    func shortcutCancellationIsAStop() throws {
        let backend = FlatBackend(entries: [.file("/root/report.txt", size: 1)])
        backend.cancelDuringSubtreeListing = true
        let results = try SubtreeSearch.find(
            under: .local("/root"),
            using: backend,
            matching: predicate(FileQuery(nameContains: "report"))
        )
        #expect(results.completion == .stopped)
        #expect(results.hits.isEmpty)
    }

    @Test("an unreadable subdirectory is skipped, not fatal")
    func unreadableIsSkipped() throws {
        let backend = tree()
        backend.unreadable = ["/root/b"]
        let results = try SubtreeSearch.find(
            under: .local("/root"),
            using: backend,
            matching: predicate(FileQuery(nameContains: "report"))
        )
        #expect(results.completion == .complete)
        // Everything outside the refused branch is still a real answer.
        #expect(Set(results.hits.map(\.name)) == ["report-top.txt", "report-a.txt"])
    }

    // MARK: - Progress

    @Test("progress is reported per directory, and its counts move")
    func progressReported() throws {
        var seen: [SubtreeSearch.Progress] = []
        _ = try SubtreeSearch.find(
            under: .local("/root"),
            using: tree(),
            matching: predicate(FileQuery(nameContains: "report")),
            onProgress: { seen.append($0) }
        )
        #expect(seen.count == 5)
        #expect(seen.map(\.directoriesListed) == [1, 2, 3, 4, 5])
        #expect(seen.last?.hits == 4)
    }

    // MARK: - The flat shortcut

    /// A backend that can answer a whole subtree in one call (S3, whose keyspace is flat) is asked
    /// for it and never walked. Pinned by the listing count: the shortcut is invisible in the hits,
    /// which are identical either way, and *not* walking is the entire benefit.
    @Test("a backend with a subtree shortcut is not walked")
    func shortcutSkipsTheWalk() throws {
        let backend = FlatBackend(entries: [
            .file("/root/a/report-a.txt", size: 1),
            .file("/root/b/deep/report-deep.txt", size: 2),
            .file("/root/b/notes.txt", size: 3)
        ])
        let results = try SubtreeSearch.find(
            under: .local("/root"),
            using: backend,
            matching: predicate(FileQuery(nameContains: "report"))
        )
        #expect(Set(results.hits.map(\.name)) == ["report-a.txt", "report-deep.txt"])
        #expect(backend.walkedDirectories == 0)
        #expect(results.directoriesListed == 1)
        #expect(results.completion == .complete)
    }

    @Test("the shortcut honours the result limit too")
    func shortcutTruncates() throws {
        let backend = FlatBackend(entries: [
            .file("/root/report-1.txt", size: 1),
            .file("/root/report-2.txt", size: 1),
            .file("/root/report-3.txt", size: 1)
        ])
        let results = try SubtreeSearch.find(
            under: .local("/root"),
            using: backend,
            matching: predicate(FileQuery(nameContains: "report")),
            limit: 2
        )
        #expect(results.hits.count == 2)
        #expect(results.completion == .truncated)
    }
}

// MARK: - Fakes

/// One row in a fake listing.
private struct FakeRow {
    let name: String
    let isDirectory: Bool
    let size: Int64

    static func dir(_ name: String) -> FakeRow {
        FakeRow(name: name, isDirectory: true, size: 0)
    }

    static func file(_ name: String, size: Int64) -> FakeRow {
        FakeRow(name: name, isDirectory: false, size: size)
    }
}

private func fakeEntry(at path: String, name: String, isDirectory: Bool, size: Int64) -> FileEntry {
    FileEntry(
        path: .local(path),
        name: name,
        kind: isDirectory ? .directory : .file,
        byteSize: size,
        modificationDate: Date(timeIntervalSince1970: 1_700_000_000),
        creationDate: Date(timeIntervalSince1970: 1_700_000_000),
        isHidden: false,
        permissions: 0o644,
        inode: 1
    )
}

/// A backend serving a fixed tree and recording every listing it was asked for.
private final class FakeTreeBackend: VFSBackend, @unchecked Sendable {
    private let directories: [String: [FakeRow]]
    private let lock = NSLock()
    private var listedPaths: [VFSPath] = []
    /// Paths that answer `permissionDenied`, for the skip-and-continue case.
    var unreadable: Set<String> = []

    init(directories: [String: [FakeRow]]) {
        self.directories = directories
    }

    var listed: [VFSPath] {
        lock.lock()
        defer { lock.unlock() }
        return listedPaths
    }

    var id: VFSBackendID { .local }
    var capabilities: VFSCapabilities { [.read] }

    func listDirectory(at path: VFSPath) throws -> [FileEntry] {
        if unreadable.contains(path.path) { throw VFSError.permissionDenied(path) }
        guard let rows = directories[path.path] else { throw VFSError.notFound(path) }
        lock.lock()
        listedPaths.append(path)
        lock.unlock()
        return rows.map {
            fakeEntry(
                at: path.path + "/" + $0.name,
                name: $0.name,
                isDirectory: $0.isDirectory,
                size: $0.size
            )
        }
    }

    func stat(at path: VFSPath) throws -> FileEntry {
        throw VFSError.notFound(path)
    }
}

/// A backend whose keyspace is flat — S3's shape — answering a whole subtree in one call and
/// counting any walk it is nonetheless asked to perform.
private final class FlatBackend: VFSBackend, @unchecked Sendable {
    struct Object {
        let path: String
        let size: Int64

        static func file(_ path: String, size: Int64) -> Object {
            Object(path: path, size: size)
        }
    }

    private let entries: [Object]
    private let lock = NSLock()
    private var walked = 0
    /// Makes the shortcut throw `CancellationError`, which is how a paged enumeration says it was
    /// stopped partway through.
    var cancelDuringSubtreeListing = false

    init(entries: [Object]) {
        self.entries = entries
    }

    var walkedDirectories: Int {
        lock.lock()
        defer { lock.unlock() }
        return walked
    }

    var id: VFSBackendID { .local }
    var capabilities: VFSCapabilities { [.read] }

    func subtreeListing(at path: VFSPath, isCancelled: () -> Bool) throws -> [FileEntry]? {
        if cancelDuringSubtreeListing { throw CancellationError() }
        return entries.map {
            fakeEntry(
                at: $0.path,
                name: ($0.path as NSString).lastPathComponent,
                isDirectory: false,
                size: $0.size
            )
        }
    }

    func listDirectory(at path: VFSPath) throws -> [FileEntry] {
        lock.lock()
        walked += 1
        lock.unlock()
        return []
    }

    func stat(at path: VFSPath) throws -> FileEntry {
        throw VFSError.notFound(path)
    }
}
