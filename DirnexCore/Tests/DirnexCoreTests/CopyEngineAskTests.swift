import Foundation
import Testing

@testable import DirnexCore

/// The `.ask` conflict policy — the engine yielding control per conflict to a resolver, the
/// core half of TC's rich per-file conflict dialog with "apply to all" (PLAN.md §M2). The
/// resolver stands in for the app's dialog: the tests script its answers and assert that the
/// engine consults it exactly on the colliding items, honours each `ConflictResolution`, and
/// unwinds cleanly when the resolver says `.cancel`.
@Suite("CopyEngine ask policy")
struct CopyEngineAskTests {
    let backend = LocalBackend()

    private func stat(_ tree: TempTree, _ relative: String) throws -> FileEntry {
        try backend.stat(at: tree.vfsPath(relative))
    }

    private func contents(_ tree: TempTree, _ relative: String) throws -> String {
        try String(contentsOfFile: tree.path(relative), encoding: .utf8)
    }

    /// One source "a.txt" ("new") colliding with "dest/a.txt" ("old").
    private func collidingTree() throws -> TempTree {
        let tree = try TempTree()
        try tree.writeFile("a.txt", contents: "new")
        try tree.makeDir("dest")
        try tree.writeFile("dest/a.txt", contents: "old")
        return tree
    }

    private func copyOp(_ tree: TempTree, sources: [String]) throws -> FileOperation {
        FileOperation(
            kind: .copy,
            sources: try sources.map { try stat(tree, $0) },
            destinationDirectory: tree.vfsPath("dest")
        )
    }

    private func run(
        _ operation: FileOperation,
        _ resolver: ScriptedResolver
    ) -> OperationReport {
        CopyEngine.run(
            operation,
            using: backend,
            conflictPolicy: .ask,
            resolveConflict: { resolver.resolve($0) }
        )
    }

    // MARK: - One resolution per case

    @Test("ask → overwrite replaces the existing item")
    func askOverwrite() throws {
        let tree = try collidingTree()
        defer { tree.cleanup() }
        let resolver = ScriptedResolver { _ in .overwrite }

        #expect(run(try copyOp(tree, sources: ["a.txt"]), resolver).succeeded)
        #expect(try contents(tree, "dest/a.txt") == "new")
        #expect(resolver.callCount == 1)
        // No temp detritus from the atomic swap.
        #expect(try backend.listDirectory(at: tree.vfsPath("dest")).map(\.name) == ["a.txt"])
    }

    @Test("ask → skip keeps the existing item and records the source skipped")
    func askSkip() throws {
        let tree = try collidingTree()
        defer { tree.cleanup() }
        let resolver = ScriptedResolver { _ in .skip }

        let report = run(try copyOp(tree, sources: ["a.txt"]), resolver)
        #expect(report.skipped == [tree.vfsPath("a.txt")])
        #expect(try contents(tree, "dest/a.txt") == "old")
    }

    @Test("ask → keepBoth transfers under a fresh name, leaving the original")
    func askKeepBoth() throws {
        let tree = try collidingTree()
        defer { tree.cleanup() }
        let resolver = ScriptedResolver { _ in .keepBoth }

        #expect(run(try copyOp(tree, sources: ["a.txt"]), resolver).succeeded)
        #expect(try contents(tree, "dest/a.txt") == "old")
        #expect(try contents(tree, "dest/a copy.txt") == "new")
    }

    @Test("ask → overwriteIfNewer replaces an older destination but keeps a newer one")
    func askOverwriteIfNewer() throws {
        let tree = try collidingTree()
        defer { tree.cleanup() }
        try tree.setModificationDate("dest/a.txt", to: Date(timeIntervalSince1970: 1000))
        try tree.setModificationDate("a.txt", to: Date(timeIntervalSince1970: 2000))
        let resolver = ScriptedResolver { _ in .overwriteIfNewer }

        #expect(run(try copyOp(tree, sources: ["a.txt"]), resolver).succeeded)
        #expect(try contents(tree, "dest/a.txt") == "new") // source was newer

        // Now with the destination newer than the source: kept.
        let older = try collidingTree()
        defer { older.cleanup() }
        try older.setModificationDate("dest/a.txt", to: Date(timeIntervalSince1970: 2000))
        try older.setModificationDate("a.txt", to: Date(timeIntervalSince1970: 1000))
        let report = run(
            try copyOp(older, sources: ["a.txt"]),
            ScriptedResolver { _ in .overwriteIfNewer }
        )
        #expect(report.skipped == [older.vfsPath("a.txt")])
        #expect(try contents(older, "dest/a.txt") == "old")
    }

    // MARK: - Only colliding items ask; cancel aborts the batch

    @Test("the resolver is consulted only for colliding sources")
    func onlyConflictsAsk() throws {
        let tree = try collidingTree()
        defer { tree.cleanup() }
        try tree.writeFile("b.txt", contents: "fresh") // no dest/b.txt — no collision
        let resolver = ScriptedResolver { _ in .overwrite }

        let report = run(try copyOp(tree, sources: ["a.txt", "b.txt"]), resolver)
        #expect(report.succeeded)
        #expect(resolver.callCount == 1) // only a.txt collided
        #expect(resolver.contexts.first?.source.name == "a.txt")
        #expect(resolver.contexts.first?.existing.path == tree.vfsPath("dest/a.txt"))
        #expect(resolver.contexts.first?.kind == .copy)
        #expect(try contents(tree, "dest/a.txt") == "new")
        #expect(try contents(tree, "dest/b.txt") == "fresh")
    }

    @Test("ask → cancel aborts the whole operation, leaving later sources untouched")
    func askCancelAborts() throws {
        let tree = try collidingTree()
        defer { tree.cleanup() }
        try tree.writeFile("b.txt", contents: "new-b")
        try tree.writeFile("dest/b.txt", contents: "old-b") // b.txt also collides
        let resolver = ScriptedResolver { _ in .cancel }

        let report = run(try copyOp(tree, sources: ["a.txt", "b.txt"]), resolver)
        #expect(report.wasCancelled)
        #expect(report.completedItems == 0)
        #expect(resolver.callCount == 1) // stopped at the first conflict
        #expect(try contents(tree, "dest/a.txt") == "old") // nothing overwritten
        #expect(try contents(tree, "dest/b.txt") == "old-b")
    }

    @Test("an ask policy with no resolver degrades to fail (never clobbers)")
    func askWithoutResolverFails() throws {
        let tree = try collidingTree()
        defer { tree.cleanup() }
        let report = CopyEngine.run(
            try copyOp(tree, sources: ["a.txt"]),
            using: backend,
            conflictPolicy: .ask
        )

        #expect(report.failures.first?.error == .alreadyExists(tree.vfsPath("dest/a.txt")))
        #expect(try contents(tree, "dest/a.txt") == "old")
    }
}

/// A test stand-in for the app's conflict dialog: records every context the engine hands it
/// and replies with a scripted `ConflictResolution`. The engine calls it synchronously on
/// its copy thread, so a plain recorder is enough (`@unchecked Sendable` to cross the
/// `@Sendable` closure boundary).
private final class ScriptedResolver: @unchecked Sendable {
    private let responder: @Sendable (ConflictContext) -> ConflictResolution
    private(set) var contexts: [ConflictContext] = []

    init(_ responder: @escaping @Sendable (ConflictContext) -> ConflictResolution) {
        self.responder = responder
    }

    func resolve(_ context: ConflictContext) -> ConflictResolution {
        contexts.append(context)
        return responder(context)
    }

    var callCount: Int { contexts.count }
}
