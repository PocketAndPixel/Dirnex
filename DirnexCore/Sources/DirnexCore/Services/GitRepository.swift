import Foundation

/// Finding the Git working tree a panel is browsing, and building the command that reads its status
/// (PLAN.md §M6 "a debounced `git status --porcelain` provider").
///
/// Pure, with the filesystem reduced to an injected `exists` probe and the spawn reduced to an argv
/// — so repository discovery and the exact flags are tested without a repository or a subprocess,
/// the same shape as `ExternalDiffTool`.
public enum GitRepository {
    /// The working-tree root containing `directory`, or `nil` when it is not inside a repository.
    ///
    /// Walks up from `directory` looking for `.git`, nearest first, so a submodule or a nested
    /// repository wins over the outer one it sits in — which matches what `git` itself would report
    /// from that directory.
    ///
    /// `exists` must be a **plain existence check**, not a directory check: `.git` is a regular file
    /// holding a `gitdir:` pointer in a linked worktree or a submodule, and treating those as
    /// non-repositories would silently drop Git awareness exactly where people use worktrees.
    public static func repositoryRoot(for directory: VFSPath, exists: (String) -> Bool) -> VFSPath? {
        // Only the real filesystem has repositories: an archive's innards or an SFTP pane never do,
        // and walking their parents would be meaningless.
        guard directory.backend == .local else { return nil }
        var candidate: VFSPath? = directory
        while let current = candidate {
            if exists(current.appending(gitDirectoryName).path) { return current }
            candidate = current.parent
        }
        return nil
    }

    private static let gitDirectoryName = ".git"
}

/// The `git` invocation the app's status provider spawns. Pure and tested so the flag set — which
/// carries two decisions that are easy to get wrong and invisible once wrong — is pinned here rather
/// than buried in a `Process` call site, exactly as `SFTPProcessArguments` pins `sftp`'s.
public enum GitCommand {
    /// Where a real `git` binary might live, most-preferred first: Homebrew (which users keep newer
    /// than Apple's), then the Command Line Tools, then the one inside Xcode.
    ///
    /// **`/usr/bin/git` is deliberately absent.** It is not `git` — it is Apple's `xcrun` shim, and
    /// running it when the Command Line Tools are *not* installed pops a modal "install developer
    /// tools?" dialog. A background poller must never be able to do that to someone who simply
    /// opened a folder. When none of these exist, Git awareness stays off and the column stays
    /// blank, which is the same graceful degradation as having no diff tool installed.
    public static let candidateExecutablePaths = [
        "/opt/homebrew/bin/git",
        "/usr/local/bin/git",
        "/Library/Developer/CommandLineTools/usr/bin/git",
        "/Applications/Xcode.app/Contents/Developer/usr/bin/git"
    ]

    /// The first candidate `executableExists` accepts, or `nil` when no usable `git` is installed.
    public static func executablePath(where executableExists: (String) -> Bool) -> String? {
        candidateExecutablePaths.first(where: executableExists)
    }

    /// The arguments that read `repositoryRoot`'s full status.
    ///
    /// - `--no-optional-locks` keeps this out of the user's way. A plain `git status` opportunistically
    ///   rewrites the index to refresh its stat cache, taking `index.lock` to do it. A poller doing
    ///   that behind someone's back races their own `git` commands and can fail *their* rebase with a
    ///   lock error. This flag makes the read side-effect-free — the same reason editors pass it.
    /// - `--porcelain=v1` is the stable machine format, immune to config and locale (`-b`'s header
    ///   included); `--branch` adds it for the path bar.
    /// - `-z` gives raw NUL-terminated fields, so paths with spaces or non-ASCII bytes arrive
    ///   unquoted (see `GitStatusParser`).
    /// - `--ignored=traditional` reports an ignored *directory* as one collapsed row rather than
    ///   listing every file under it — the difference between one row for `node_modules/` and a
    ///   hundred thousand of them.
    public static func status(repositoryRoot: String) -> [String] {
        [
            "--no-optional-locks",
            "-C", repositoryRoot,
            "status",
            "--porcelain=v1",
            "--branch",
            "-z",
            "--ignored=traditional"
        ]
    }
}
