import Foundation
import Testing

@testable import DirnexCore

@Suite("GitStatusSnapshot")
struct GitStatusSnapshotTests {
    private let root = VFSPath.local("/Users/me/repo")

    private func snapshot(_ entries: [(String, String)]) -> GitStatusSnapshot {
        GitStatusSnapshot(
            repositoryRoot: root,
            branch: GitBranch(name: "main"),
            entries: entries.map { path, code in
                let characters = Array(code)
                return GitStatusEntry(
                    relativePath: path,
                    indexStatus: characters[0],
                    worktreeStatus: characters[1]
                )
            }
        )
    }

    // MARK: - Lookup

    @Test("a reported file answers with its own status")
    func exactLookup() {
        let tree = snapshot([("sub/file.txt", " M")])
        #expect(tree.status(forRelativePath: "sub/file.txt") == .modified)
    }

    @Test("an unreported file in a clean tree is unmodified")
    func unreportedIsClean() {
        let tree = snapshot([("other.txt", " M")])
        #expect(tree.status(forRelativePath: "clean.txt") == .unmodified)
    }

    @Test("the repository root itself is never painted")
    func rootIsUnmodified() {
        // Rolling the whole repo up onto its own row would mark the `..` entry of every dirty repo.
        let tree = snapshot([("a.txt", " M")])
        #expect(tree.status(forRelativePath: "") == .unmodified)
        #expect(tree.status(for: root) == .unmodified)
    }

    // MARK: - Directory roll-up

    @Test("a directory takes the status of what is inside it, at every level")
    func rollsUpThroughAncestors() {
        let tree = snapshot([("sub/deep/nested.txt", " M")])
        #expect(tree.status(forRelativePath: "sub/deep") == .modified)
        #expect(tree.status(forRelativePath: "sub") == .modified)
    }

    @Test("a directory reports the loudest status among its descendants")
    func rollupUsesPrecedence() {
        let tree = snapshot([
            ("sub/edited.txt", " M"),
            ("sub/conflicted.txt", "UU"),
            ("sub/new.txt", "??")
        ])
        // A conflict outranks an edit, which outranks an untracked file.
        #expect(tree.status(forRelativePath: "sub") == .conflicted)

        let quieter = snapshot([("sub/edited.txt", " M"), ("sub/new.txt", "??")])
        #expect(quieter.status(forRelativePath: "sub") == .modified)
    }

    @Test("an ignored file does not make its folder look ignored")
    func ignoredDoesNotRollUp() {
        // `src/` is an ordinary tracked folder that happens to hold one ignored log.
        let tree = snapshot([("src/debug.log", "!!")])
        #expect(tree.status(forRelativePath: "src/debug.log") == .ignored)
        #expect(tree.status(forRelativePath: "src") == .unmodified)
    }

    @Test("an ignored directory Git reported is still marked itself")
    func ignoredDirectoryIsMarked() {
        // Git collapses it to one row with a trailing slash; the row itself must read as ignored.
        let tree = snapshot([("node_modules/", "!!")])
        #expect(tree.status(forRelativePath: "node_modules") == .ignored)
    }

    @Test("an exact entry beats the roll-up of its contents")
    func exactEntryBeatsRollup() {
        let tree = snapshot([("sub", "??"), ("sub/inner.txt", " M")])
        #expect(tree.status(forRelativePath: "sub") == .untracked)
    }

    // MARK: - Collapsed-directory inheritance

    @Test("files inside a collapsed untracked directory inherit it")
    func inheritsUntrackedAncestor() {
        // Git emits `untrackeddir/` and nothing about its contents, but the panel still shows them
        // once someone navigates in — they must not read as clean, tracked files.
        let tree = snapshot([("untrackeddir/", "??")])
        #expect(tree.status(forRelativePath: "untrackeddir/x/f.txt") == .untracked)
        #expect(tree.status(forRelativePath: "untrackeddir/x") == .untracked)
    }

    @Test("files inside a collapsed ignored directory inherit it")
    func inheritsIgnoredAncestor() {
        let tree = snapshot([("node_modules/", "!!")])
        #expect(tree.status(forRelativePath: "node_modules/pkg/index.js") == .ignored)
    }

    @Test("the nearest collapsed ancestor wins")
    func nearestAncestorWins() {
        let tree = snapshot([("outer/", "??"), ("outer/inner/", "!!")])
        #expect(tree.status(forRelativePath: "outer/inner/f.txt") == .ignored)
    }

    @Test("a modified ancestor is not inherited downwards")
    func modifiedIsNotInherited() {
        // Only untracked/ignored collapse. A modified `sub/file.txt` says nothing about a sibling.
        let tree = snapshot([("sub/file.txt", " M")])
        #expect(tree.status(forRelativePath: "sub/other.txt") == .unmodified)
    }

    // MARK: - Path mapping

    @Test("an absolute path inside the repository maps to its relative key")
    func mapsAbsolutePaths() {
        let tree = snapshot([("sub/file.txt", " M")])
        #expect(
            tree.relativePath(for: root.appending("sub").appending("file.txt")) == "sub/file.txt"
        )
        #expect(tree.status(for: root.appending("sub").appending("file.txt")) == .modified)
        #expect(tree.status(for: root.appending("sub")) == .modified)
    }

    @Test("a path outside the repository is not mapped")
    func rejectsOutsidePaths() {
        let tree = snapshot([("a.txt", " M")])
        #expect(tree.relativePath(for: .local("/Users/me/elsewhere/a.txt")) == nil)
        #expect(tree.status(for: .local("/Users/me/elsewhere/a.txt")) == .unmodified)
        // A sibling whose name merely starts with the root's name is not inside it.
        #expect(tree.relativePath(for: .local("/Users/me/repo-backup/a.txt")) == nil)
    }

    @Test("a non-local path is never mapped")
    func rejectsNonLocalBackends() {
        // An archive's innards or an SFTP pane can't be in this working tree.
        let tree = snapshot([("a.txt", " M")])
        let inArchive = VFSPath(
            backend: .archive(forArchiveAt: "/Users/me/repo/x.zip"),
            path: "/a.txt"
        )
        #expect(tree.relativePath(for: inArchive) == nil)
        #expect(tree.status(for: inArchive) == .unmodified)
    }

    @Test("a repository at the filesystem root maps paths correctly")
    func repositoryAtFilesystemRoot() {
        let tree = GitStatusSnapshot(
            repositoryRoot: .local("/"),
            branch: GitBranch(name: "main"),
            entries: [
                GitStatusEntry(relativePath: "etc/hosts", indexStatus: " ", worktreeStatus: "M")
            ]
        )
        #expect(tree.relativePath(for: .local("/etc/hosts")) == "etc/hosts")
        #expect(tree.status(for: .local("/etc/hosts")) == .modified)
    }

    // MARK: - Unicode

    @Test("a decomposed on-disk name matches the precomposed name Git reports")
    func matchesAcrossUnicodeNormalization() {
        // Captured live: the filesystem hands back `nfd-e` + U+0301, while Git (with
        // core.precomposeunicode, on by default on macOS) reports the precomposed `nfd-é`. Swift's
        // String compares and hashes by canonical equivalence, so the two keys are interchangeable —
        // this pins that assumption, since it is exactly what a byte-keyed map would get wrong.
        let precomposed = "nfd-\u{00E9}.txt"
        let decomposed = "nfd-e\u{0301}.txt"
        #expect(Array(precomposed.utf8) != Array(decomposed.utf8))

        let tree = snapshot([(precomposed, "??")])
        #expect(tree.status(forRelativePath: decomposed) == .untracked)
        #expect(tree.status(for: root.appending(decomposed)) == .untracked)
    }

    // MARK: - .gitignore-aware sizing

    @Test("an ignored directory and everything inside it is excluded from a total")
    func excludesIgnoredSubtree() {
        // Exactly what `--ignored=traditional` emits: the directory collapsed to one row, with not
        // a word about its contents.
        let tree = snapshot([("build", "!!")])
        #expect(tree.isExcludedFromSize(root.appending("build")))
        #expect(tree.isExcludedFromSize(root.appending("build").appending("deep/a.o")))
    }

    @Test("a source folder holding one ignored file is not itself excluded")
    func ignoredFileDoesNotExcludeItsFolder() {
        // The load-bearing half of `GitFileStatus.rollsUpToAncestors`: were `.ignored` to roll up
        // like every other status, one stray `debug.log` would delete `src` from the chart.
        let tree = snapshot([("src/debug.log", "!!")])
        #expect(tree.isExcludedFromSize(root.appending("src/debug.log")))
        #expect(!tree.isExcludedFromSize(root.appending("src")))
        #expect(!tree.isExcludedFromSize(root.appending("src/main.swift")))
    }

    @Test("an ignored directory nested in an untracked one is excluded")
    func excludesIgnoredInsideUntracked() {
        // Probed against a real repository: `untracked/build/` is reported even though its parent is
        // merely untracked, so the ignore data needs no second `git` run to be complete here.
        let tree = snapshot([("untracked", "??"), ("untracked/build", "!!")])
        #expect(tree.isExcludedFromSize(root.appending("untracked/build/b.o")))
        // The untracked parent is the user's own content and stays in the total.
        #expect(!tree.isExcludedFromSize(root.appending("untracked")))
        #expect(!tree.isExcludedFromSize(root.appending("untracked/keep.txt")))
    }

    @Test("`.git` is excluded even though Git never reports it")
    func excludesGitDirectory() {
        // It appears in no `status` output, ignored or otherwise (probed), so nothing but this rule
        // keeps the object store — routinely the largest thing in the tree — out of the total.
        let tree = snapshot([])
        #expect(tree.isExcludedFromSize(root.appending(".git")))
        #expect(tree.isExcludedFromSize(root.appending(".git/objects/pack")))
        // Including a nested repository's, whose own ignore rules this snapshot cannot see.
        #expect(tree.isExcludedFromSize(root.appending("vendor/lib/.git")))
    }

    @Test("nothing outside the repository is excluded")
    func keepsPathsOutsideRepository() {
        let tree = snapshot([("build", "!!")])
        #expect(!tree.isExcludedFromSize(.local("/elsewhere/build")))
        // The root itself is a folder someone can point at; it must produce a number.
        #expect(!tree.isExcludedFromSize(root))
    }

    @Test("ignoredPaths reports the exclusions and nothing else about the tree")
    func ignoredPathsIsolatesTheRules() {
        // The basis for "did the rules change?" — it must not move when an ordinary edit does, or a
        // repository under a build would re-walk every sized folder several times a second.
        let before = snapshot([("build", "!!"), ("src/main.swift", " M")])
        let afterEdit = snapshot([("build", "!!"), ("src/main.swift", "M "), ("new.txt", "??")])
        let afterIgnoreChange = snapshot([("build", "!!"), ("dist", "!!"), ("src/main.swift", " M")])

        #expect(before.ignoredPaths == ["build"])
        #expect(before.ignoredPaths == afterEdit.ignoredPaths)
        #expect(before != afterEdit) // the snapshots differ; the rules did not
        #expect(before.ignoredPaths != afterIgnoreChange.ignoredPaths)
    }

    // MARK: - Empty

    @Test("a clean tree answers unmodified for everything")
    func cleanTree() {
        let clean = GitStatusSnapshot(repositoryRoot: root, branch: GitBranch(name: "main"))
        #expect(clean.entries.isEmpty)
        #expect(clean.status(forRelativePath: "anything/at/all.txt") == .unmodified)
        #expect(clean.branch.name == "main")
    }
}
