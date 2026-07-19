import Foundation
import Testing

@testable import DirnexCore

@Suite("DirectorySync — comparison")
struct DirectorySyncComparisonTests {
    let backend = LocalBackend()
    /// A fixed reference instant so mtime-driven statuses are deterministic.
    let base = Date(timeIntervalSince1970: 1_700_000_000)

    /// Build a temp tree with empty `L` and `R` roots to compare.
    private func twoRoots() throws -> TempTree {
        let tree = try TempTree()
        try tree.makeDir("L")
        try tree.makeDir("R")
        return tree
    }

    private func compare(
        _ tree: TempTree,
        comparison: SyncComparison = .sizeAndDate,
        includingIdentical: Bool = false,
        contentsEqual: @escaping (VFSPath, VFSPath) throws -> Bool = {
            try ByteComparator.localFilesEqual($0, $1)
        }
    ) throws -> [SyncEntry] {
        try DirectorySync.compare(
            left: tree.vfsPath("L"),
            right: tree.vfsPath("R"),
            leftBackend: backend,
            rightBackend: backend,
            comparison: comparison,
            includingIdentical: includingIdentical,
            contentsEqual: contentsEqual
        )
    }

    private func entry(_ results: [SyncEntry], _ path: String) -> SyncEntry? {
        results.first { $0.relativePath == path }
    }

    @Test("one-sided files are reported as left-only / right-only")
    func oneSidedFiles() throws {
        let tree = try twoRoots()
        defer { tree.cleanup() }
        try tree.writeFile("L/a.txt", contents: "x")
        try tree.writeFile("R/b.txt", contents: "y")

        let results = try compare(tree)
        #expect(results.count == 2)
        #expect(entry(results, "a.txt")?.status == .leftOnly)
        #expect(entry(results, "b.txt")?.status == .rightOnly)
    }

    @Test("identical files are omitted by default but shown with includingIdentical")
    func identicalOmittedByDefault() throws {
        let tree = try twoRoots()
        defer { tree.cleanup() }
        try tree.writeFile("L/same.txt", contents: "hello")
        try tree.writeFile("R/same.txt", contents: "hello")
        try tree.setModificationDate("L/same.txt", to: base)
        try tree.setModificationDate("R/same.txt", to: base)

        #expect(try compare(tree).isEmpty)

        let withIdentical = try compare(tree, includingIdentical: true)
        #expect(withIdentical.count == 1)
        #expect(entry(withIdentical, "same.txt")?.status == .identical)
    }

    @Test("size+date reports the newer side when files differ")
    func newerSideDetected() throws {
        let tree = try twoRoots()
        defer { tree.cleanup() }
        try tree.writeFile("L/f.txt", contents: "newer bigger content")
        try tree.writeFile("R/f.txt", contents: "old")
        try tree.setModificationDate("L/f.txt", to: base.addingTimeInterval(60))
        try tree.setModificationDate("R/f.txt", to: base)

        #expect(entry(try compare(tree), "f.txt")?.status == .leftNewer)

        // Flip the timestamps: now the right copy is the newer one.
        try tree.setModificationDate("L/f.txt", to: base)
        try tree.setModificationDate("R/f.txt", to: base.addingTimeInterval(60))
        #expect(entry(try compare(tree), "f.txt")?.status == .rightNewer)
    }

    @Test("differing files with equal mtimes read as differ, with no newer side")
    func differWhenSameTimeDifferentSize() throws {
        let tree = try twoRoots()
        defer { tree.cleanup() }
        // Different sizes but identical mtimes — clearly not equal, yet neither is newer.
        try tree.writeFile("L/f.txt", contents: "aaaa")
        try tree.writeFile("R/f.txt", contents: "bbbbb")
        try tree.setModificationDate("L/f.txt", to: base)
        try tree.setModificationDate("R/f.txt", to: base)

        #expect(entry(try compare(tree), "f.txt")?.status == .differ)
    }

    @Test("both-sides directories are recursed with correct relative paths, no row for the folder")
    func nestedDirectoriesRecursed() throws {
        let tree = try twoRoots()
        defer { tree.cleanup() }
        try tree.makeDir("L/sub")
        try tree.makeDir("R/sub")
        try tree.writeFile("L/sub/x.txt", contents: "left version")
        try tree.writeFile("R/sub/x.txt", contents: "right")
        try tree.setModificationDate("L/sub/x.txt", to: base.addingTimeInterval(60))
        try tree.setModificationDate("R/sub/x.txt", to: base)
        try tree.writeFile("L/sub/y.txt", contents: "only left")

        let results = try compare(tree)
        // The shared "sub" directory itself is not a row.
        #expect(entry(results, "sub") == nil)
        #expect(entry(results, "sub/x.txt")?.status == .leftNewer)
        #expect(entry(results, "sub/y.txt")?.status == .leftOnly)
    }

    @Test("a directory present on only one side is a single non-recursed subtree row")
    func oneSidedDirectoryIsOneRow() throws {
        let tree = try twoRoots()
        defer { tree.cleanup() }
        try tree.makeDir("L/onlydir/deep")
        try tree.writeFile("L/onlydir/deep/a.txt", contents: "buried")

        let results = try compare(tree)
        #expect(results.count == 1)
        let row = entry(results, "onlydir")
        #expect(row?.status == .leftOnly)
        #expect(row?.isDirectory == true)
        // The buried file is not enumerated — the whole subtree copies as one unit.
        #expect(entry(results, "onlydir/deep/a.txt") == nil)
    }

    @Test("a file on one side and a directory on the other is a type mismatch")
    func typeMismatch() throws {
        let tree = try twoRoots()
        defer { tree.cleanup() }
        try tree.writeFile("L/thing", contents: "i am a file")
        try tree.makeDir("R/thing")

        let row = entry(try compare(tree), "thing")
        #expect(row?.status == .typeMismatch)
        #expect(row?.isDirectory == true) // it's a directory on the right
    }

    @Test("content mode catches a same-size, same-mtime edit that size+date misses")
    func contentModeCatchesSilentEdit() throws {
        let tree = try twoRoots()
        defer { tree.cleanup() }
        try tree.writeFile("L/f.txt", contents: "aaaa")
        try tree.writeFile("R/f.txt", contents: "aaba") // same 4 bytes length
        try tree.setModificationDate("L/f.txt", to: base)
        try tree.setModificationDate("R/f.txt", to: base)

        // size+date is fooled — identical, so omitted.
        #expect(try compare(tree).isEmpty)
        // content mode sees the byte difference; equal mtimes make it a tie → differ.
        #expect(entry(try compare(tree, comparison: .content), "f.txt")?.status == .differ)
    }

    @Test("content mode reports identical when the bytes match")
    func contentModeIdentical() throws {
        let tree = try twoRoots()
        defer { tree.cleanup() }
        try tree.writeFile("L/f.txt", contents: "aaaa")
        try tree.writeFile("R/f.txt", contents: "aaaa")
        try tree.setModificationDate("L/f.txt", to: base)
        try tree.setModificationDate("R/f.txt", to: base)

        #expect(try compare(tree, comparison: .content).isEmpty)
        let shown = try compare(tree, comparison: .content, includingIdentical: true)
        #expect(entry(shown, "f.txt")?.status == .identical)
    }

    @Test("content mode short-circuits on a size mismatch without invoking the comparator")
    func contentModeSizeShortCircuit() throws {
        let tree = try twoRoots()
        defer { tree.cleanup() }
        try tree.writeFile("L/f.txt", contents: "short")
        try tree.writeFile("R/f.txt", contents: "much longer contents")
        try tree.setModificationDate("L/f.txt", to: base.addingTimeInterval(60))
        try tree.setModificationDate("R/f.txt", to: base)

        // The comparator would throw if called — but different sizes decide equality first.
        struct Boom: Error {}
        let results = try compare(tree, comparison: .content) { _, _ in throw Boom() }
        #expect(entry(results, "f.txt")?.status == .leftNewer)
    }

    @Test("an injected comparator drives content-mode equality for equal-size files")
    func injectedComparator() throws {
        let tree = try twoRoots()
        defer { tree.cleanup() }
        try tree.writeFile("L/f.txt", contents: "aaaa")
        try tree.writeFile("R/f.txt", contents: "bbbb") // equal size, real bytes differ
        try tree.setModificationDate("L/f.txt", to: base)
        try tree.setModificationDate("R/f.txt", to: base)

        // Force "equal" — the whole row disappears despite differing bytes.
        #expect(try compare(tree, comparison: .content) { _, _ in true }.isEmpty)
        // Force "unequal" — equal mtimes make it a differ.
        let unequal = try compare(tree, comparison: .content) { _, _ in false }
        #expect(entry(unequal, "f.txt")?.status == .differ)
    }

    @Test("results are sorted by relative path")
    func sortedOutput() throws {
        let tree = try twoRoots()
        defer { tree.cleanup() }
        for name in ["m.txt", "a.txt", "z.txt", "c.txt"] {
            try tree.writeFile("L/\(name)", contents: "x")
        }

        let paths = try compare(tree).map(\.relativePath)
        #expect(paths == paths.sorted())
        #expect(paths == ["a.txt", "c.txt", "m.txt", "z.txt"])
    }

    @Test("a listing failure propagates rather than being silently treated as empty")
    func listingErrorPropagates() throws {
        let tree = try TempTree()
        defer { tree.cleanup() }
        try tree.makeDir("R") // left root does not exist

        #expect(throws: (any Error).self) {
            _ = try DirectorySync.compare(
                left: tree.vfsPath("L"),
                right: tree.vfsPath("R"),
                leftBackend: backend,
                rightBackend: backend
            )
        }
    }

    @Test("cancellation aborts the scan with CancellationError")
    func cancels() throws {
        let tree = try twoRoots()
        defer { tree.cleanup() }
        try tree.writeFile("L/a.txt", contents: "x")

        #expect(throws: CancellationError.self) {
            _ = try DirectorySync.compare(
                left: tree.vfsPath("L"),
                right: tree.vfsPath("R"),
                leftBackend: backend,
                rightBackend: backend,
                isCancelled: { true }
            )
        }
    }
}

@Suite("DirectorySync — default actions")
struct DirectorySyncActionTests {
    @Test("left-to-right mirror copies changes rightward and prunes right-only items")
    func leftToRight() {
        func action(_ status: SyncStatus) -> SyncAction {
            DirectorySync.defaultAction(for: status, direction: .leftToRight)
        }
        #expect(action(.leftOnly) == .copyToRight)
        #expect(action(.rightOnly) == .deleteRight)
        #expect(action(.leftNewer) == .copyToRight)
        #expect(action(.rightNewer) == .copyToRight) // mirror is authoritative
        #expect(action(.differ) == .copyToRight)
        #expect(action(.identical) == .none)
        #expect(action(.typeMismatch) == .conflict)
    }

    @Test("right-to-left mirror is the exact mirror image")
    func rightToLeft() {
        func action(_ status: SyncStatus) -> SyncAction {
            DirectorySync.defaultAction(for: status, direction: .rightToLeft)
        }
        #expect(action(.leftOnly) == .deleteLeft)
        #expect(action(.rightOnly) == .copyToLeft)
        #expect(action(.leftNewer) == .copyToLeft)
        #expect(action(.rightNewer) == .copyToLeft)
        #expect(action(.differ) == .copyToLeft)
        #expect(action(.identical) == .none)
        #expect(action(.typeMismatch) == .conflict)
    }

    @Test("bidirectional unions the trees, newer wins, nothing is deleted, ties are conflicts")
    func bidirectional() {
        func action(_ status: SyncStatus) -> SyncAction {
            DirectorySync.defaultAction(for: status, direction: .bidirectional)
        }
        #expect(action(.leftOnly) == .copyToRight)
        #expect(action(.rightOnly) == .copyToLeft)
        #expect(action(.leftNewer) == .copyToRight)
        #expect(action(.rightNewer) == .copyToLeft)
        #expect(action(.differ) == .conflict)
        #expect(action(.identical) == .none)
        #expect(action(.typeMismatch) == .conflict)
    }

    @Test("SyncEntry.defaultAction matches the free function")
    func entryConvenienceMatches() {
        let entry = SyncEntry(
            relativePath: "a.txt", name: "a.txt",
            left: nil, right: nil, status: .leftOnly
        )
        #expect(entry.defaultAction(for: .leftToRight) == .copyToRight)
        #expect(entry.defaultAction(for: .rightToLeft) == .deleteLeft)
    }
}

@Suite("DirectorySync — override actions")
struct DirectorySyncOverrideTests {
    @Test("a one-sided item can be propagated or deleted from its side")
    func oneSidedOverrides() {
        #expect(DirectorySync.availableActions(for: .leftOnly) == [.copyToRight, .deleteLeft])
        #expect(DirectorySync.availableActions(for: .rightOnly) == [.copyToLeft, .deleteRight])
    }

    @Test("a both-sides difference can be copied either way, but never deleted")
    func bothSidesOverrides() {
        for status in [SyncStatus.leftNewer, .rightNewer, .differ] {
            #expect(DirectorySync.availableActions(for: status) == [.copyToRight, .copyToLeft])
        }
    }

    @Test("identical and type-mismatch rows offer no override")
    func noOverrideForIdenticalOrClash() {
        #expect(DirectorySync.availableActions(for: .identical).isEmpty)
        #expect(DirectorySync.availableActions(for: .typeMismatch).isEmpty)
    }

    @Test("override lists exclude the non-runnable .none and .conflict")
    func overridesAreRunnable() {
        for status in [SyncStatus.leftOnly, .rightOnly, .leftNewer, .rightNewer, .differ] {
            let actions = DirectorySync.availableActions(for: status)
            #expect(!actions.contains(.none))
            #expect(!actions.contains(.conflict))
        }
    }

    @Test("SyncEntry.availableActions matches the free function")
    func entryConvenienceMatches() {
        let entry = SyncEntry(
            relativePath: "a.txt", name: "a.txt",
            left: nil, right: nil, status: .rightOnly
        )
        #expect(entry.availableActions == [.copyToLeft, .deleteRight])
    }
}
