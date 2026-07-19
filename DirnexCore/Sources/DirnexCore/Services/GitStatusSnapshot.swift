import Foundation

/// A whole repository's Git state at one instant: the branch for the path bar, and every path Git
/// had something to say about, indexed for the per-row lookup a panel does while rendering
/// (PLAN.md §M6 "Git awareness").
///
/// A panel asks this one question per visible row — `status(for:)` — so the answer must be O(1) and
/// allocation-free. All the work happens once, here, at construction:
///
/// - **Directory roll-up.** Git reports files; a panel also shows the folders containing them. Every
///   entry's ancestors are pre-merged into `directoryStatus` by `GitFileStatus.rollupPrecedence`, so
///   a folder advertises the loudest thing inside it (a conflict beats an edit beats a new file).
/// - **Collapsed-directory inheritance.** Git does not list the files inside an untracked or ignored
///   directory — it emits the single row `build/` and stops. So a lookup that misses falls back to
///   the nearest ancestor carrying such a status, and the files inside `build/` still read as
///   ignored once someone navigates in.
/// - **Unicode.** macOS hands back decomposed filenames (`e` + a combining acute) while Git — with
///   `core.precomposeunicode`, on by default there — reports the precomposed form, so the two spell
///   the same file with different bytes. This needs no normalizing pass because Swift's `String`
///   compares *and hashes* by canonical equivalence, making the two keys interchangeable in the
///   dictionary for free. That is a load-bearing assumption rather than an obvious one — it would
///   silently break in any language whose strings compare bytewise — so a test pins it, and nothing
///   here pays to re-normalize a key on every row.
public struct GitStatusSnapshot: Sendable, Equatable {
    /// Absolute path of the working tree's root — the directory holding `.git`.
    public let repositoryRoot: VFSPath
    /// The branch `HEAD` is on.
    public let branch: GitBranch
    /// Every reported path, keyed by normalized repository-relative path.
    public let entries: [String: GitStatusEntry]

    /// Pre-merged status of each directory that has a reported descendant.
    private let directoryStatus: [String: GitFileStatus]

    public init(repositoryRoot: VFSPath, branch: GitBranch, entries: [GitStatusEntry]) {
        self.repositoryRoot = repositoryRoot
        self.branch = branch

        var byPath: [String: GitStatusEntry] = [:]
        var rollup: [String: GitFileStatus] = [:]
        for entry in entries {
            let key = Self.normalizeKey(entry.relativePath)
            guard !key.isEmpty else { continue }
            byPath[key] = entry

            let status = entry.status
            guard status.rollsUpToAncestors else { continue }
            for ancestor in Self.ancestorKeys(of: key) {
                if let current = rollup[ancestor], current.rollupPrecedence >= status.rollupPrecedence {
                    continue
                }
                rollup[ancestor] = status
            }
        }
        self.entries = byPath
        directoryStatus = rollup
    }

    /// An empty snapshot for `repositoryRoot` — a clean working tree, where every row is unmodified.
    public init(repositoryRoot: VFSPath, branch: GitBranch) {
        self.init(repositoryRoot: repositoryRoot, branch: branch, entries: [])
    }

    /// The status of one panel row. Anything outside this repository (another volume, an archive, an
    /// SFTP pane) is `.unmodified` — the column simply stays blank rather than guessing.
    public func status(for path: VFSPath) -> GitFileStatus {
        guard let relativePath = relativePath(for: path) else { return .unmodified }
        return status(forRelativePath: relativePath)
    }

    /// The status of a repository-relative path (`sub/file.txt`), directory or file.
    ///
    /// Resolution order: the path's own entry, then its roll-up as a directory, then a collapsed
    /// untracked/ignored ancestor, then `.unmodified`. Only directories can hold a roll-up, so the
    /// caller need not say which it is asking about — a file has no descendants to merge.
    public func status(forRelativePath relativePath: String) -> GitFileStatus {
        let key = Self.normalizeKey(relativePath)
        // The repository root itself: its roll-up would be "the whole repo is dirty", which is not a
        // useful thing to paint on a `..` row.
        guard !key.isEmpty else { return .unmodified }
        if let entry = entries[key] { return entry.status }
        if let rolled = directoryStatus[key] { return rolled }
        return inheritedStatus(forKey: key)
    }

    /// This path expressed relative to the repository root, or `nil` when it lies outside the
    /// repository or on a non-local backend. The root itself maps to `""`.
    public func relativePath(for path: VFSPath) -> String? {
        guard path.backend == .local, path.isSelfOrDescendant(of: repositoryRoot) else { return nil }
        let root = repositoryRoot.path
        // Dropping the root prefix leaves a leading slash ("/Users/me/repo" + "/sub"), except at the
        // filesystem root where `VFSPath` has already normalized the trailing slash away.
        let suffix = path.path.dropFirst(root.count)
        return String(suffix.drop { $0 == "/" })
    }

    /// Whether a path is left out of a `.gitignore`-aware folder total (PLAN.md §M6, the optional
    /// slice of Git awareness): everything Git ignores, plus any `.git` directory.
    ///
    /// This is `DirectorySizer`'s prune predicate, and it is deliberately built out of the very
    /// snapshot the status column already renders — so **the rows left out of the total are exactly
    /// the rows already painted `!`**, and a folder whose size shrank has an on-screen explanation.
    /// It needs no new `git` run for the same reason: `GitCommand.status` already passes
    /// `--ignored=traditional`, which reports each ignored directory as one collapsed row (probed:
    /// even `untracked/build/`, an ignored directory nested inside an *untracked* one, is listed).
    ///
    /// Two properties of `GitFileStatus` make the one-line `.ignored` test right rather than merely
    /// convenient, and both are pinned by tests because a change to either would silently move
    /// bytes: `.ignored` does **not** roll up to ancestors, so a source folder holding one ignored
    /// `debug.log` is not itself pruned; and it **is** inherited by descendants, so everything
    /// inside a collapsed `build/` is pruned without Git having listed any of it.
    ///
    /// **`.git` is excluded even though Git never reports it** (probed — it appears in no `status`
    /// output, ignored or otherwise). It is the repository's own bookkeeping rather than the user's
    /// content, and it is routinely one of the largest directories in the tree; leaving it in would
    /// make "what of this is mine" answer mostly "the object store". Matching on the name rather
    /// than on the root's own `.git` also prunes the metadata of **nested** repositories and
    /// submodules, whose ignore rules this snapshot cannot see at all (probed: the outer status
    /// reports a nested repository as a single `?? nested/` and says nothing about its contents).
    /// That is the known limit of this feature, not an oversight.
    ///
    /// Anything outside this repository is kept, since these rules do not describe it.
    public func isExcludedFromSize(_ path: VFSPath) -> Bool {
        guard let relativePath = relativePath(for: path), !relativePath.isEmpty else { return false }
        if Self.isGitMetadata(relativePath) { return true }
        return status(forRelativePath: relativePath) == .ignored
    }

    /// Whether a repository-relative path *is* a `.git` or lies inside one.
    ///
    /// Testing every component rather than just the last one costs an extra pass and, in the walk,
    /// almost never changes the answer — `DirectorySizer` prunes `.git` at its own boundary and so
    /// never descends into it. It matters for the predicate asked in isolation, which is how the
    /// **`..` row and Space-on-dir** reach it: a caller that starts *inside* the object store would
    /// otherwise be told its contents count.
    private static func isGitMetadata(_ relativePath: String) -> Bool {
        relativePath.split(separator: "/").contains { $0 == gitDirectoryName }
    }

    /// The repository metadata directory — a directory in a normal clone, a `gitdir:` pointer *file*
    /// in a worktree or submodule, and pruned in either case.
    private static let gitDirectoryName = ".git"

    /// Every path Git reported as ignored — precisely what `isExcludedFromSize` prunes, and nothing
    /// else about the working tree.
    ///
    /// This exists so a caller can ask *"did the exclusions change?"* rather than *"did anything
    /// change?"*, and the distinction is what keeps git-aware totals from thrashing. Two snapshots
    /// differ (`Equatable`) the instant one file is saved, and the app's status provider republishes
    /// on **every** debounced read whether or not anything moved; hanging cache invalidation on that
    /// would re-walk every folder on screen each time the user hit ⌘S. The ignored set, by contrast,
    /// only moves when the rules do — a `.gitignore` edit, a branch switch, a `git add` of a
    /// previously ignored file — which is exactly when a git-aware total stops being true.
    public var ignoredPaths: Set<String> {
        Set(entries.lazy.filter { $0.value.status == .ignored }.map(\.key))
    }

    /// The status of the nearest untracked or ignored ancestor — the directory Git collapsed —
    /// or `.unmodified` when there is none.
    private func inheritedStatus(forKey key: String) -> GitFileStatus {
        for ancestor in Self.ancestorKeys(of: key) {
            guard let status = entries[ancestor]?.status else { continue }
            return status.isInheritedByDescendants ? status : .unmodified
        }
        return .unmodified
    }

    /// A relative path reduced to its lookup key: no leading or trailing slash — Git marks a
    /// collapsed directory with a trailing one, and a caller may pass a rooted path. Unicode needs no
    /// handling here; see the type's note on canonical equivalence.
    static func normalizeKey(_ relativePath: String) -> String {
        var key = Substring(relativePath)
        while key.hasPrefix("/") { key = key.dropFirst() }
        while key.hasSuffix("/") { key = key.dropLast() }
        return String(key)
    }

    /// Every strict ancestor of an already-normalized key, nearest first: `a/b/c.txt` → `a/b`, `a`.
    /// Nearest-first is what makes `inheritedStatus` pick the innermost collapsed directory.
    static func ancestorKeys(of key: String) -> [String] {
        var ancestors: [String] = []
        var current = Substring(key)
        while let slash = current.lastIndex(of: "/") {
            current = current[..<slash]
            ancestors.append(String(current))
        }
        return ancestors
    }
}
