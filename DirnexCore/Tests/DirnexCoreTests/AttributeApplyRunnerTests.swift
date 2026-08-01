import Foundation
import Testing

@testable import DirnexCore

/// What a recursive attributes apply *writes* (PLAN.md §M14 Slice 4), against real files. What it
/// leaves behind — undo material, failures, counts — is `AttributeApplyReportTests`.
///
/// The one that justifies the whole design is ``locksItselfOutWithoutPostOrder``: it makes the run
/// write a mode that removes a directory's search bit, which is exactly what `chmod -R 0644` does to
/// a tree, and asserts every item underneath still got changed. A pre-order implementation passes
/// every other test here and fails only that one.
@Suite("AttributeApplyRunner")
struct AttributeApplyRunnerTests {
    // MARK: - The ordering criterion

    /// The reason the run applies deepest-first. `0o644` on a directory removes its search bit, and
    /// a pre-order walk would then be unable to resolve a single path underneath it — every child
    /// `chmod` comes back `EPERM` (measured; see `AttributeApplyScope.applicationOrder`).
    @Test("A mode that makes directories unwalkable still reaches every item")
    func locksItselfOutWithoutPostOrder() throws {
        let fixture = try AttributeApplyFixture()
        defer { fixture.cleanup() }
        // Start the files somewhere else, so each one genuinely has to be written and a run that
        // silently skipped the deep ones could not still count six.
        for file in ["a.txt", "sub/b.txt", "sub/deep/c.txt"] {
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o600], ofItemAtPath: fixture.tree.path(file)
            )
        }

        let report = try fixture.run(AttributeApplyJob(patch: fixture.patch(mode: 0o644)))

        // A pre-order run fails here and nowhere else: with the parent written first, every child
        // path stops resolving and each `chmod` under it comes back EPERM.
        #expect(report.failures.isEmpty, "\(report.failures)")
        #expect(try fixture.outcome(report).changedCount == 6, "three directories and three files")

        // And the modes really landed. Reading them back means re-opening the tree one level at a
        // time — which is the ordering problem, seen from the other side.
        fixture.restoreTraversal()
        #expect(try fixture.mode("a.txt") == 0o644)
        #expect(try fixture.mode("sub") == 0o644)
        fixture.restoreTraversal("sub")
        #expect(try fixture.mode("sub/b.txt") == 0o644)
        #expect(try fixture.mode("sub/deep") == 0o644)
        fixture.restoreTraversal("sub/deep")
        #expect(try fixture.mode("sub/deep/c.txt") == 0o644)
    }

    // MARK: - Scope

    @Test("The roots are always applied, even when the filter excludes their kind")
    func rootsAlwaysApply() throws {
        let fixture = try AttributeApplyFixture()
        defer { fixture.cleanup() }

        let report = try fixture.run(
            AttributeApplyJob(patch: fixture.patch(mode: 0o700), target: .filesOnly)
        )

        #expect(report.failures.isEmpty, "\(report.failures)")
        #expect(try fixture.mode() == 0o700, "the root the sheet was opened on must change")
        #expect(try fixture.mode("a.txt") == 0o700)
        #expect(try fixture.mode("sub/deep/c.txt") == 0o700)
        #expect(try fixture.mode("sub") == 0o755, "an enclosed folder is out of scope for filesOnly")
        #expect(try fixture.mode("sub/deep") == 0o755)
    }

    @Test("Folders only leaves every enclosed file alone")
    func foldersOnly() throws {
        let fixture = try AttributeApplyFixture()
        defer { fixture.cleanup() }

        let report = try fixture.run(
            AttributeApplyJob(patch: fixture.patch(mode: 0o750), target: .foldersOnly)
        )

        #expect(report.failures.isEmpty, "\(report.failures)")
        #expect(try fixture.mode("sub") == 0o750)
        #expect(try fixture.mode("sub/deep") == 0o750)
        #expect(try fixture.mode("a.txt") == 0o644)
        #expect(try fixture.mode("sub/b.txt") == 0o644)
    }

    @Test("A run over one file touches nothing else")
    func singleFileSource() throws {
        let fixture = try AttributeApplyFixture()
        defer { fixture.cleanup() }

        let report = try fixture.run(
            AttributeApplyJob(patch: fixture.patch(mode: 0o600)), sources: ["sub/b.txt"]
        )

        #expect(try fixture.mode("sub/b.txt") == 0o600)
        #expect(try fixture.mode("a.txt") == 0o644)
        #expect(try fixture.outcome(report).changedCount == 1)
    }

    // MARK: - The patch stays a patch

    @Test("An untouched bit keeps each item's own value, even when they disagree")
    func mixedBitStaysMixed() throws {
        let fixture = try AttributeApplyFixture()
        defer { fixture.cleanup() }
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600], ofItemAtPath: fixture.tree.path("a.txt")
        )
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o644], ofItemAtPath: fixture.tree.path("sub/b.txt")
        )

        // Force owner-execute only. Everyone-read differs between the two files and is untouched.
        var patch = AttributePatch()
        patch.permissionMask[.owner, .execute] = true
        patch.permissionValues[.owner, .execute] = true

        let report = try fixture.run(AttributeApplyJob(patch: patch, target: .filesOnly))

        #expect(report.failures.isEmpty, "\(report.failures)")
        #expect(try fixture.mode("a.txt") == 0o700)
        #expect(try fixture.mode("sub/b.txt") == 0o744)
    }

    @Test("An item already matching the patch is visited but never written")
    func alreadyMatchingIsNotChanged() throws {
        let fixture = try AttributeApplyFixture()
        defer { fixture.cleanup() }

        let job = AttributeApplyJob(patch: fixture.patch(setting: .hidden), target: .filesOnly)
        let first = try fixture.run(job)
        #expect(try fixture.outcome(first).changedCount == 4, "the root plus its three files")

        let second = try fixture.run(job)
        let result = try fixture.outcome(second)
        #expect(result.changedCount == 0, "nothing differs from the patch any more")
        #expect(result.visitedCount == 4, "and yet every item was still visited")
        #expect(UndoRecord.attributeBatchChange(result.changed) == nil)
    }

    @Test("An empty job does nothing at all")
    func emptyJob() throws {
        let fixture = try AttributeApplyFixture()
        defer { fixture.cleanup() }

        let report = try fixture.run(AttributeApplyJob(patch: AttributePatch()))

        #expect(try fixture.outcome(report).changedCount == 0)
        #expect(try fixture.mode("a.txt") == 0o644)
    }

    // MARK: - Symlinks

    @Test("A symlink is changed on the link itself and never descended through")
    func symlinksAreNotFollowed() throws {
        let fixture = try AttributeApplyFixture()
        defer { fixture.cleanup() }
        // A link back into the tree's own root: following it would recurse forever.
        try fixture.tree.symlink("sub/loop", to: fixture.tree.path(""))

        let report = try fixture.run(AttributeApplyJob(patch: fixture.patch(setting: .hidden)))

        #expect(report.failures.isEmpty, "\(report.failures)")
        // Six real items plus the link, each visited exactly once — a followed link would have
        // walked the whole tree again through it, and again through that.
        #expect(try fixture.outcome(report).visitedCount == 7)
        var stats = Darwin.stat()
        #expect(lstat(fixture.tree.path("sub/loop"), &stats) == 0)
        #expect(stats.st_mode & S_IFMT == S_IFLNK, "the link itself must survive, not its target")
        // `lchflags`, not `chflags`: the flag landed on the link, which is the whole `l*` rule the
        // rest of the attributes machinery follows.
        #expect(stats.st_flags & UInt32(UF_HIDDEN) != 0)
    }
}
