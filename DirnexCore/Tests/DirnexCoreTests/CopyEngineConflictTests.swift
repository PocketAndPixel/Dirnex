import Foundation
import Testing

@testable import DirnexCore

/// The conflict-policy matrix for the copy/move engine (PLAN.md §M2): what happens to each
/// source whose destination is already occupied under fail / skip / overwrite / newerOnly /
/// keepBoth. Split out of `CopyEngineTests` to keep each suite focused (and under the file's
/// length limits) as the policy set grows.
@Suite("CopyEngine conflicts")
struct CopyEngineConflictTests {
    let backend = LocalBackend()

    private func stat(_ tree: TempTree, _ relative: String) throws -> FileEntry {
        try backend.stat(at: tree.vfsPath(relative))
    }

    private func contents(_ tree: TempTree, _ relative: String) throws -> String {
        try String(contentsOfFile: tree.path(relative), encoding: .utf8)
    }

    /// A source "a.txt" (contents "new") whose destination "dest/a.txt" (contents "old")
    /// already exists — the shape every conflict-policy test starts from.
    private func collidingTree() throws -> TempTree {
        let tree = try TempTree()
        try tree.writeFile("a.txt", contents: "new")
        try tree.makeDir("dest")
        try tree.writeFile("dest/a.txt", contents: "old")
        return tree
    }

    private func copyOp(_ tree: TempTree) throws -> FileOperation {
        FileOperation(
            kind: .copy,
            sources: [try stat(tree, "a.txt")],
            destinationDirectory: tree.vfsPath("dest")
        )
    }

    // MARK: - fail / skip / overwrite / keepBoth

    @Test("the default fail policy records a failure and leaves the existing item")
    func conflictFailRecordsFailure() throws {
        let tree = try collidingTree()
        defer { tree.cleanup() }
        let report = CopyEngine.run(try copyOp(tree), using: backend) // .fail default

        #expect(report.failures.count == 1)
        #expect(report.failures.first?.error == .alreadyExists(tree.vfsPath("dest/a.txt")))
        #expect(try contents(tree, "dest/a.txt") == "old") // untouched
    }

    @Test("skip leaves the existing item and records the source as skipped")
    func conflictSkip() throws {
        let tree = try collidingTree()
        defer { tree.cleanup() }
        let report = CopyEngine.run(try copyOp(tree), using: backend, conflictPolicy: .skip)

        #expect(report.skipped == [tree.vfsPath("a.txt")])
        #expect(try contents(tree, "dest/a.txt") == "old")
    }

    @Test("overwrite replaces the existing item's contents")
    func conflictOverwrite() throws {
        let tree = try collidingTree()
        defer { tree.cleanup() }
        #expect(
            CopyEngine.run(try copyOp(tree), using: backend, conflictPolicy: .overwrite).succeeded
        )
        #expect(try contents(tree, "dest/a.txt") == "new")
        // No temporary detritus left behind.
        #expect(try backend.listDirectory(at: tree.vfsPath("dest")).map(\.name) == ["a.txt"])
    }

    @Test("keepBoth copies under a fresh name, leaving the original")
    func conflictKeepBoth() throws {
        let tree = try collidingTree()
        defer { tree.cleanup() }
        #expect(
            CopyEngine.run(try copyOp(tree), using: backend, conflictPolicy: .keepBoth).succeeded
        )
        #expect(try contents(tree, "dest/a.txt") == "old")
        #expect(try contents(tree, "dest/a copy.txt") == "new")
    }

    // MARK: - newerOnly (TC's "overwrite older")

    @Test("newerOnly overwrites when the source is newer than the destination")
    func conflictNewerOnlyReplacesOlder() throws {
        let tree = try collidingTree()
        defer { tree.cleanup() }
        try tree.setModificationDate("dest/a.txt", to: Date(timeIntervalSince1970: 1000))
        try tree.setModificationDate("a.txt", to: Date(timeIntervalSince1970: 2000))

        let report = CopyEngine.run(try copyOp(tree), using: backend, conflictPolicy: .newerOnly)

        #expect(report.succeeded)
        #expect(report.skipped.isEmpty)
        #expect(try contents(tree, "dest/a.txt") == "new")
        #expect(try backend.listDirectory(at: tree.vfsPath("dest")).map(\.name) == ["a.txt"])
    }

    @Test("newerOnly skips when the source is older than the destination")
    func conflictNewerOnlyKeepsNewer() throws {
        let tree = try collidingTree()
        defer { tree.cleanup() }
        try tree.setModificationDate("dest/a.txt", to: Date(timeIntervalSince1970: 2000))
        try tree.setModificationDate("a.txt", to: Date(timeIntervalSince1970: 1000))

        let report = CopyEngine.run(try copyOp(tree), using: backend, conflictPolicy: .newerOnly)

        #expect(report.skipped == [tree.vfsPath("a.txt")])
        #expect(try contents(tree, "dest/a.txt") == "old") // the newer destination is kept
    }

    @Test("newerOnly skips when the timestamps are equal (not strictly newer)")
    func conflictNewerOnlySkipsEqual() throws {
        let tree = try collidingTree()
        defer { tree.cleanup() }
        let sameDate = Date(timeIntervalSince1970: 1500)
        try tree.setModificationDate("dest/a.txt", to: sameDate)
        try tree.setModificationDate("a.txt", to: sameDate)

        let report = CopyEngine.run(try copyOp(tree), using: backend, conflictPolicy: .newerOnly)

        #expect(report.skipped == [tree.vfsPath("a.txt")])
        #expect(try contents(tree, "dest/a.txt") == "old")
    }
}
