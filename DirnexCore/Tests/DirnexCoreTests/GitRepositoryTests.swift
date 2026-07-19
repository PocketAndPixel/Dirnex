import Foundation
import Testing

@testable import DirnexCore

@Suite("GitRepository")
struct GitRepositoryTests {
    /// A probe reporting exactly these paths as existing.
    private func probe(_ existing: Set<String>) -> (String) -> Bool {
        { existing.contains($0) }
    }

    @Test("walks up to the working-tree root")
    func findsRootFromNestedDirectory() {
        let root = GitRepository.repositoryRoot(
            for: .local("/Users/me/repo/src/deep"),
            exists: probe(["/Users/me/repo/.git"])
        )
        #expect(root == .local("/Users/me/repo"))
    }

    @Test("a directory that is itself the root is found")
    func findsRootAtItself() {
        let root = GitRepository.repositoryRoot(
            for: .local("/Users/me/repo"),
            exists: probe(["/Users/me/repo/.git"])
        )
        #expect(root == .local("/Users/me/repo"))
    }

    @Test("the nearest repository wins over the one containing it")
    func nearestRepositoryWins() {
        // A submodule (or any nested repo) is what `git` itself would report from inside it.
        let root = GitRepository.repositoryRoot(
            for: .local("/Users/me/repo/vendor/lib/src"),
            exists: probe(["/Users/me/repo/.git", "/Users/me/repo/vendor/lib/.git"])
        )
        #expect(root == .local("/Users/me/repo/vendor/lib"))
    }

    @Test("a .git file counts, not just a .git directory")
    func gitFileCounts() {
        // A linked worktree or submodule stores `.git` as a regular file holding a `gitdir:` pointer.
        // The probe is a plain existence check for exactly this reason.
        let root = GitRepository.repositoryRoot(
            for: .local("/Users/me/worktree/src"),
            exists: probe(["/Users/me/worktree/.git"])
        )
        #expect(root == .local("/Users/me/worktree"))
    }

    @Test("a directory outside any repository has no root")
    func noRepository() {
        #expect(
            GitRepository.repositoryRoot(for: .local("/Users/me/docs"), exists: probe([])) == nil
        )
    }

    @Test("the walk terminates at the filesystem root")
    func terminatesAtRoot() {
        // Nothing exists anywhere: the loop must end rather than spin at "/".
        #expect(GitRepository.repositoryRoot(for: .local("/"), exists: probe([])) == nil)
        // A repository at "/" is unusual but legal.
        #expect(
            GitRepository.repositoryRoot(for: .local("/"), exists: probe(["/.git"])) == .local("/")
        )
    }

    @Test("non-local paths are never in a repository")
    func rejectsNonLocalBackends() {
        let inArchive = VFSPath(backend: .archive(forArchiveAt: "/Users/me/x.zip"), path: "/src")
        // The probe would answer for any path; the backend check must reject before asking.
        #expect(GitRepository.repositoryRoot(for: inArchive, exists: { _ in true }) == nil)
    }
}

@Suite("GitCommand")
struct GitCommandTests {
    @Test("the status invocation carries the flags the provider depends on")
    func statusArguments() {
        #expect(GitCommand.status(repositoryRoot: "/Users/me/repo") == [
            "--no-optional-locks",
            "-C", "/Users/me/repo",
            "status",
            "--porcelain=v1",
            "--branch",
            "-z",
            "--ignored=traditional"
        ])
    }

    @Test("--no-optional-locks precedes the subcommand")
    func globalFlagsComeFirst() {
        // Git only accepts its global options before the subcommand; getting this backwards would
        // make every status call fail at runtime while looking perfectly reasonable here.
        let arguments = GitCommand.status(repositoryRoot: "/repo")
        let lockIndex = arguments.firstIndex(of: "--no-optional-locks")
        let statusIndex = arguments.firstIndex(of: "status")
        #expect(lockIndex != nil)
        #expect(statusIndex != nil)
        #expect((lockIndex ?? 0) < (statusIndex ?? 0))
        #expect((arguments.firstIndex(of: "-C") ?? 0) < (statusIndex ?? 0))
    }

    @Test("the executable is the first installed candidate, preferring Homebrew")
    func executablePathPrefersFirst() {
        let all = GitCommand.executablePath(where: { _ in true })
        #expect(all == "/opt/homebrew/bin/git")

        let clt = GitCommand.executablePath(
            where: { $0 == "/Library/Developer/CommandLineTools/usr/bin/git" }
        )
        #expect(clt == "/Library/Developer/CommandLineTools/usr/bin/git")
    }

    @Test("no installed git means no Git awareness, rather than a fallback")
    func executablePathNilWhenMissing() {
        #expect(GitCommand.executablePath(where: { _ in false }) == nil)
    }

    @Test("the xcrun shim is never a candidate")
    func neverUsesTheShim() {
        // Spawning /usr/bin/git without the Command Line Tools installed pops a modal install
        // dialog. A background poller must never be able to trigger that, so the shim is not on the
        // list at any priority — the column degrades to blank instead.
        #expect(!GitCommand.candidateExecutablePaths.contains("/usr/bin/git"))
        #expect(GitCommand.candidateExecutablePaths.allSatisfy { $0.hasPrefix("/") })
    }
}
