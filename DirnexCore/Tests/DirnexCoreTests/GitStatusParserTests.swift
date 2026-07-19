import Foundation
import Testing

@testable import DirnexCore

@Suite("GitStatusParser")
struct GitStatusParserTests {
    private let root = VFSPath.local("/repo")

    /// Verbatim `git status --porcelain=v1 --branch -z --ignored=traditional` output, captured from
    /// git 2.50.1 against a scratch repository built to hold one of every shape at once. Pinning the
    /// real bytes — rather than output written from memory — is what keeps this parser honest; the
    /// `sftp` listing parser had to be reworked precisely because its format was assumed, not
    /// observed.
    private let liveOutput = """
    ## main\0A  .gitignore\0AM bothmod.txt\0R  renamed.txt\0torename.txt\0A  stagedadd.txt\0\
     D todelete.txt\0 M tracked.txt\0?? untracked.txt\0?? untrackeddir/\0!! node_modules/\0
    """

    @Test("parses every entry shape from real git output")
    func parsesLiveOutput() {
        let snapshot = GitStatusParser.parse(porcelain: liveOutput, repositoryRoot: root)

        #expect(snapshot.branch.name == "main")
        // Ten fields, but the rename's source is not an entry of its own — nine entries.
        #expect(snapshot.entries.count == 9)
        #expect(snapshot.entries["stagedadd.txt"]?.status == .added)
        #expect(snapshot.entries["todelete.txt"]?.status == .deleted)
        #expect(snapshot.entries["tracked.txt"]?.status == .modified)
        #expect(snapshot.entries["untracked.txt"]?.status == .untracked)
        // A collapsed directory arrives with a trailing slash; the key drops it.
        #expect(snapshot.entries["untrackeddir"]?.status == .untracked)
        #expect(snapshot.entries["node_modules"]?.status == .ignored)
        // Staged add plus later edits: the index column wins, and the worktree edit is retained.
        #expect(snapshot.entries["bothmod.txt"]?.status == .added)
        #expect(snapshot.entries["bothmod.txt"]?.worktreeStatus == "M")
    }

    @Test("a rename is keyed by its new path, with the original from the following field")
    func renameReadsBothFields() {
        let snapshot = GitStatusParser.parse(porcelain: liveOutput, repositoryRoot: root)

        // The trap: `-z` emits `R  <new>` NUL `<old>`, the reverse of the printed `old -> new`.
        // Reading them in the printed order would key this row by the file that no longer exists.
        let renamed = snapshot.entries["renamed.txt"]
        #expect(renamed?.status == .renamed)
        #expect(renamed?.originalPath == "torename.txt")
        // The source path must not have become an entry in its own right.
        #expect(snapshot.entries["torename.txt"] == nil)
    }

    @Test("a rename source is not mistaken for the next entry")
    func renameDoesNotSwallowFollowingEntry() {
        // `old.txt` is the rename's source field; ` M after.txt` must still parse as its own entry.
        let snapshot = GitStatusParser.parse(
            porcelain: "## main\0R  new.txt\0old.txt\0 M after.txt\0",
            repositoryRoot: root
        )
        #expect(snapshot.entries.count == 2)
        #expect(snapshot.entries["new.txt"]?.originalPath == "old.txt")
        #expect(snapshot.entries["after.txt"]?.status == .modified)
    }

    @Test("paths keep spaces and non-ASCII bytes verbatim")
    func preservesAwkwardPaths() {
        // `-z` is unquoted, so a space is just a space — no `"…"` wrapper to strip.
        let snapshot = GitStatusParser.parse(
            porcelain: "## main\0 M my report.txt\0?? emoji-🎉.txt\0",
            repositoryRoot: root
        )
        #expect(snapshot.entries["my report.txt"]?.status == .modified)
        #expect(snapshot.entries["emoji-🎉.txt"]?.status == .untracked)
    }

    @Test("nested paths keep their full relative form")
    func keepsNestedPaths() {
        let snapshot = GitStatusParser.parse(
            porcelain: "## main\0 M sub/deep/nested.txt\0",
            repositoryRoot: root
        )
        #expect(snapshot.entries["sub/deep/nested.txt"]?.status == .modified)
    }

    @Test("malformed fields are skipped without losing the rest")
    func skipsMalformedFields() {
        // "XY" with no space, and a too-short field, sit between two good entries.
        let snapshot = GitStatusParser.parse(
            porcelain: "## main\0 M good.txt\0XXbad\0?\0 M also-good.txt\0",
            repositoryRoot: root
        )
        #expect(snapshot.entries.count == 2)
        #expect(snapshot.entries["good.txt"]?.status == .modified)
        #expect(snapshot.entries["also-good.txt"]?.status == .modified)
    }

    @Test("output without a branch header still yields entries")
    func survivesMissingHeader() {
        let snapshot = GitStatusParser.parse(porcelain: " M a.txt\0", repositoryRoot: root)
        #expect(snapshot.entries["a.txt"]?.status == .modified)
        #expect(snapshot.branch.isDetached)
    }

    @Test("empty output is a clean tree")
    func handlesEmptyOutput() {
        #expect(GitStatusParser.parse(porcelain: "", repositoryRoot: root).entries.isEmpty)
        let clean = GitStatusParser.parse(porcelain: "## main\0", repositoryRoot: root)
        #expect(clean.entries.isEmpty)
        #expect(clean.branch.name == "main")
    }
}

// MARK: - Branch header

@Suite("GitStatusParser branch header")
struct GitStatusParserBranchTests {
    private let root = VFSPath.local("/repo")

    private func branch(_ header: String) -> GitBranch {
        GitStatusParser.parse(porcelain: header + "\0", repositoryRoot: root).branch
    }

    @Test("a branch with no upstream")
    func plainBranch() {
        let parsed = branch("## main")
        #expect(parsed.name == "main")
        #expect(parsed.upstream == nil)
        #expect(!parsed.isDetached)
        #expect(parsed.ahead == 0)
        #expect(parsed.behind == 0)
    }

    @Test("a branch tracking an upstream, in sync")
    func upstreamInSync() {
        let parsed = branch("## main...origin/main")
        #expect(parsed.name == "main")
        #expect(parsed.upstream == "origin/main")
        #expect(parsed.ahead == 0)
        #expect(parsed.behind == 0)
    }

    @Test("ahead, behind, and both are read from the tracking bracket")
    func upstreamDivergence() {
        #expect(branch("## main...origin/main [ahead 1]").ahead == 1)
        #expect(branch("## main...origin/main [ahead 1]").behind == 0)
        #expect(branch("## main...origin/main [behind 2]").behind == 2)

        // Captured live: both directions in one bracket.
        let diverged = branch("## main...origin/main [ahead 1, behind 1]")
        #expect(diverged.ahead == 1)
        #expect(diverged.behind == 1)
        #expect(diverged.upstream == "origin/main")
    }

    @Test("a deleted upstream reports no divergence rather than a bad number")
    func upstreamGone() {
        let parsed = branch("## main...origin/main [gone]")
        #expect(parsed.upstream == "origin/main")
        #expect(parsed.ahead == 0)
        #expect(parsed.behind == 0)
    }

    @Test("a detached HEAD has no branch name")
    func detachedHead() {
        let parsed = branch("## HEAD (no branch)")
        #expect(parsed.name == nil)
        #expect(parsed.isDetached)
        #expect(parsed.displayName == "detached HEAD")
    }

    @Test("a fresh repository reports its branch and that it has no commits")
    func noCommitsYet() {
        let parsed = branch("## No commits yet on main")
        #expect(parsed.name == "main")
        #expect(parsed.hasNoCommits)
        #expect(!parsed.isDetached)
        #expect(parsed.displayName == "main")
    }

    @Test("a fresh repository that already has an upstream set")
    func noCommitsWithUpstream() {
        let parsed = branch("## No commits yet on main...origin/main")
        #expect(parsed.name == "main")
        #expect(parsed.upstream == "origin/main")
        #expect(parsed.hasNoCommits)
    }

    @Test("a slashed branch name survives, and cannot be confused with its upstream")
    func slashedBranchName() {
        // Refname rules forbid ".." in a branch, so "..." unambiguously separates name from upstream.
        let parsed = branch("## feature/git-column...origin/feature/git-column [ahead 3]")
        #expect(parsed.name == "feature/git-column")
        #expect(parsed.upstream == "origin/feature/git-column")
        #expect(parsed.ahead == 3)
    }
}
