import Foundation

/// What Git says about one path in a working tree (PLAN.md §M6 "Git awareness: status column
/// (M/A/?/ignored)"). This is the single state a panel row renders, distilled from Git's two-axis
/// index/worktree pair — see `GitStatusEntry.status` for how the two axes collapse into one.
public enum GitFileStatus: Sendable, Hashable, CaseIterable {
    /// Tracked and unchanged — the overwhelming majority of rows, and the one that renders nothing.
    case unmodified
    /// Contents changed (Git's `M`), or the type changed, e.g. file → symlink (`T`).
    case modified
    /// A new path staged for the next commit (`A`).
    case added
    /// A tracked path removed from the worktree or the index (`D`).
    case deleted
    /// Moved or copied from another path (`R`/`C`); `GitStatusEntry.originalPath` names the source.
    case renamed
    /// Not tracked and not ignored (`??`) — Git knows nothing about it.
    case untracked
    /// Excluded by a `.gitignore` rule (`!!`).
    case ignored
    /// An unresolved merge conflict (any unmerged index state) — the one status that demands action.
    case conflicted

    /// Git's own one-letter vocabulary for the state, or `nil` when there is nothing to show. The
    /// letters are Git's, not a Dirnex invention, so they live here rather than in the app — the app
    /// picks the colour, this picks the character.
    public var code: String? {
        switch self {
        case .unmodified: nil
        case .modified: "M"
        case .added: "A"
        case .deleted: "D"
        case .renamed: "R"
        case .untracked: "?"
        case .ignored: "!"
        case .conflicted: "U"
        }
    }

    /// How loudly a status calls for attention, used to pick a directory's single roll-up status
    /// when its descendants disagree: an unresolved conflict outranks an edit, which outranks a new
    /// file, which outranks something Git is ignoring entirely.
    var rollupPrecedence: Int {
        switch self {
        case .unmodified: 0
        case .ignored: 1
        case .untracked: 2
        case .renamed: 3
        case .deleted: 4
        case .added: 5
        case .modified: 6
        case .conflicted: 7
        }
    }

    /// Whether a descendant carrying this status should colour its ancestor directories.
    ///
    /// Everything actionable rolls up — a folder should advertise the modified file buried inside it.
    /// `.ignored` deliberately does **not**: a normal source folder holding one ignored `debug.log`
    /// is not itself ignored, and painting it `!` would say exactly that. An *ignored directory* is
    /// still marked, because Git reports that directory itself (see `GitStatusSnapshot`'s collapsing
    /// note), not merely its contents.
    var rollsUpToAncestors: Bool {
        self != .ignored && self != .unmodified
    }

    /// Whether this status is inherited by everything beneath it. Git collapses an untracked or
    /// ignored *directory* into a single entry and says nothing about the files inside, so those
    /// files take their status from the nearest such ancestor.
    var isInheritedByDescendants: Bool {
        self == .untracked || self == .ignored
    }
}

/// One `git status --porcelain` record: a path plus Git's two status axes.
///
/// Git reports a path twice over — `indexStatus` is what is staged for the next commit, and
/// `worktreeStatus` is what differs between the index and the files on disk. Both are kept verbatim
/// so a future tooltip can say "staged edit, plus unstaged edits on top" without re-parsing, while
/// `status` collapses them into the single value a column renders.
public struct GitStatusEntry: Sendable, Hashable {
    /// Slash-separated, relative to the repository root, exactly as Git printed it (the trailing
    /// slash Git puts on a collapsed directory is stripped by `GitStatusSnapshot`'s key handling).
    public let relativePath: String
    /// Git's index (staged) column, `" "` when nothing is staged.
    public let indexStatus: Character
    /// Git's worktree (unstaged) column, `" "` when the worktree matches the index.
    public let worktreeStatus: Character
    /// Where a renamed or copied path came from (`R`/`C` only), else `nil`.
    public let originalPath: String?

    public init(
        relativePath: String,
        indexStatus: Character,
        worktreeStatus: Character,
        originalPath: String? = nil
    ) {
        self.relativePath = relativePath
        self.indexStatus = indexStatus
        self.worktreeStatus = worktreeStatus
        self.originalPath = originalPath
    }

    /// The two axes collapsed into the one status a row shows.
    ///
    /// Untracked (`??`), ignored (`!!`) and unmerged states are whole-entry verdicts and answer
    /// first. Otherwise the **index** column wins when it is set: for `AM` — a new file staged, then
    /// edited again — "added" is the more useful thing to tell someone browsing a folder than
    /// "modified", and the same holds for a renamed-then-edited `RM`. When nothing is staged the
    /// worktree column answers, which is the common ` M`/` D` case.
    public var status: GitFileStatus {
        if indexStatus == "?", worktreeStatus == "?" { return .untracked }
        if indexStatus == "!", worktreeStatus == "!" { return .ignored }
        if isUnmerged { return .conflicted }
        return Self.status(for: indexStatus) ?? Self.status(for: worktreeStatus) ?? .unmodified
    }

    /// Git's unmerged states: either side literally `U`, or the `AA`/`DD` both-added/both-deleted
    /// pair. Every one of them means the same thing to a file manager — a conflict to resolve.
    private var isUnmerged: Bool {
        if indexStatus == "U" || worktreeStatus == "U" { return true }
        return (indexStatus == "A" && worktreeStatus == "A")
            || (indexStatus == "D" && worktreeStatus == "D")
    }

    /// One of Git's per-axis letters, or `nil` for an unset (`" "`) axis.
    private static func status(for code: Character) -> GitFileStatus? {
        switch code {
        // A type change (file → symlink) is a modification as far as a panel row is concerned.
        case "M", "T": .modified
        case "A": .added
        case "D": .deleted
        case "R", "C": .renamed
        default: nil
        }
    }
}

/// Which branch a working tree is on, for the path bar (PLAN.md §M6 "branch in path bar"), parsed
/// from `git status --branch`'s `## …` header.
public struct GitBranch: Sendable, Hashable {
    /// The current branch, or `nil` when `HEAD` is detached.
    public let name: String?
    /// The tracked remote branch (`origin/main`), or `nil` when the branch has no upstream.
    public let upstream: String?
    /// Commits this branch has that its upstream does not.
    public let ahead: Int
    /// Commits the upstream has that this branch does not.
    public let behind: Int
    /// `HEAD` points at a commit rather than a branch.
    public let isDetached: Bool
    /// A branch that exists but has no commits yet — a freshly `git init`ed repository.
    public let hasNoCommits: Bool

    public init(
        name: String?,
        upstream: String? = nil,
        ahead: Int = 0,
        behind: Int = 0,
        isDetached: Bool = false,
        hasNoCommits: Bool = false
    ) {
        self.name = name
        self.upstream = upstream
        self.ahead = ahead
        self.behind = behind
        self.isDetached = isDetached
        self.hasNoCommits = hasNoCommits
    }

    /// A detached `HEAD`, as Git's `## HEAD (no branch)` header reports it.
    public static let detached = GitBranch(name: nil, isDetached: true)

    /// What the path bar shows.
    public var displayName: String {
        name ?? "detached HEAD"
    }
}
