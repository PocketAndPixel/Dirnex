import Foundation

/// Turns `git status --porcelain=v1 --branch -z` output into a `GitStatusSnapshot`.
///
/// Pure and tested, so the format — pinned against real `git` 2.50 output — is verified without
/// spawning anything, exactly as `SFTPListingParser` is for `sftp`'s `ls -la`. The app's provider
/// stays a thin spawn-and-parse shell.
///
/// **Why `-z`.** Without it, Git quotes any path containing a space, a quote, or a non-ASCII byte
/// (`"caf\303\251.txt"`), and the parser would have to reimplement C-string unquoting. With `-z`
/// every field is raw bytes terminated by NUL: no quoting, no escaping, no ambiguity. The cost is
/// that the format becomes field- rather than line-oriented, which is what the two traps below are.
///
/// **Trap 1 — the rename pair.** A rename or copy occupies *two* fields, and they are ordered
/// opposite to the human-readable form. `git status` prints `R  old -> new`, but `-z` emits
/// `R  new` NUL `old` NUL — the new path rides in the entry field and the original follows in its
/// own field. Reading them in the printed order would name every renamed row after the file that no
/// longer exists.
///
/// **Trap 2 — the branch header.** `## main...origin/main [ahead 1]` is NUL-terminated like any
/// entry rather than newline-terminated, so it is just the first field, not a separate line.
public enum GitStatusParser {
    /// Parse `porcelain` (the raw `-z` output) into a snapshot rooted at `repositoryRoot`.
    ///
    /// Unrecognized fields are skipped rather than failing the parse: a snapshot that is missing one
    /// exotic row still renders a useful panel, whereas throwing would blank the whole column. A
    /// missing `##` header — impossible from `--branch`, but cheap to survive — yields a detached
    /// branch.
    public static func parse(porcelain: String, repositoryRoot: VFSPath) -> GitStatusSnapshot {
        let fields = porcelain.split(separator: "\0", omittingEmptySubsequences: false)
        var branch = GitBranch.detached
        var entries: [GitStatusEntry] = []

        var index = 0
        while index < fields.count {
            let field = fields[index]
            index += 1
            guard !field.isEmpty else { continue }

            // An entry field always starts with two status characters and a space, so no filename
            // can be mistaken for the header (an untracked `## foo` arrives as `?? ## foo`).
            if field.hasPrefix(branchHeaderPrefix) {
                branch = parseBranch(header: String(field.dropFirst(branchHeaderPrefix.count)))
                continue
            }
            guard let record = parseEntry(field) else { continue }

            // Trap 1: consume the following field as the rename/copy source.
            var originalPath: String?
            if record.expectsOriginalPath, index < fields.count {
                originalPath = String(fields[index])
                index += 1
            }
            entries.append(
                GitStatusEntry(
                    relativePath: record.relativePath,
                    indexStatus: record.indexStatus,
                    worktreeStatus: record.worktreeStatus,
                    originalPath: originalPath
                )
            )
        }
        return GitStatusSnapshot(repositoryRoot: repositoryRoot, branch: branch, entries: entries)
    }

    // MARK: - Entries

    /// One entry field before its rename source (if any) has been read.
    private struct EntryRecord {
        let relativePath: String
        let indexStatus: Character
        let worktreeStatus: Character

        /// Whether Git will have emitted a second field naming where this path came from.
        var expectsOriginalPath: Bool {
            indexStatus == "R" || indexStatus == "C" || worktreeStatus == "R" || worktreeStatus == "C"
        }
    }

    /// `XY <path>` → a record, or `nil` when the field is too short or malformed.
    private static func parseEntry(_ field: Substring) -> EntryRecord? {
        // Two status characters, a separating space, and at least one character of path.
        guard field.count >= 4 else { return nil }
        var cursor = field.startIndex
        let indexStatus = field[cursor]
        cursor = field.index(after: cursor)
        let worktreeStatus = field[cursor]
        cursor = field.index(after: cursor)
        guard field[cursor] == " " else { return nil }
        cursor = field.index(after: cursor)
        return EntryRecord(
            relativePath: String(field[cursor...]),
            indexStatus: indexStatus,
            worktreeStatus: worktreeStatus
        )
    }

    // MARK: - Branch header

    private static let branchHeaderPrefix = "## "
    private static let detachedHeader = "HEAD (no branch)"
    private static let noCommitsPrefix = "No commits yet on "
    private static let upstreamSeparator = "..."

    /// Parse the `##` header's body, in the four shapes Git emits (all captured live):
    /// `main` · `main...origin/main [ahead 1, behind 1]` · `HEAD (no branch)` ·
    /// `No commits yet on main`.
    private static func parseBranch(header: String) -> GitBranch {
        guard header != detachedHeader else { return .detached }

        var rest = Substring(header)
        var hasNoCommits = false
        if rest.hasPrefix(noCommitsPrefix) {
            hasNoCommits = true
            rest = rest.dropFirst(noCommitsPrefix.count)
        }

        // A branch name cannot contain "..", so the upstream separator is unambiguous — Git's own
        // refname rules (`git check-ref-format`) forbid it.
        guard let separator = rest.range(of: upstreamSeparator) else {
            return GitBranch(name: String(rest), hasNoCommits: hasNoCommits)
        }
        let name = String(rest[..<separator.lowerBound])
        let tail = rest[separator.upperBound...]

        // "origin/main [ahead 1, behind 1]" — the bracketed part is present only when the branch
        // has drifted from its upstream.
        guard let bracket = tail.firstIndex(of: "[") else {
            return GitBranch(
                name: name,
                upstream: String(tail).trimmingCharacters(in: .whitespaces),
                hasNoCommits: hasNoCommits
            )
        }
        let tracking = tail[bracket...]
        return GitBranch(
            name: name,
            upstream: String(tail[..<bracket]).trimmingCharacters(in: .whitespaces),
            // A deleted upstream reads "[gone]", which carries no numbers and correctly yields 0/0.
            ahead: count(in: tracking, after: "ahead"),
            behind: count(in: tracking, after: "behind"),
            hasNoCommits: hasNoCommits
        )
    }

    /// The number following `keyword` in the tracking bracket, or 0 when absent.
    private static func count(in text: Substring, after keyword: String) -> Int {
        guard let range = text.range(of: keyword + " ") else { return 0 }
        return Int(text[range.upperBound...].prefix(while: \.isNumber)) ?? 0
    }
}
