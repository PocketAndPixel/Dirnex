import Foundation

/// One command's ranking against a palette query: the command, its score (higher is
/// better), and the character positions in the title that matched, so the palette can bold
/// them. `titleMatchOffsets` is empty when the command matched only through a keyword.
public struct CommandMatch: Sendable, Equatable {
    public let command: Command
    public let score: Int
    /// Zero-based indices into `command.title` that the query matched, for highlighting.
    public let titleMatchOffsets: [Int]

    public init(command: Command, score: Int, titleMatchOffsets: [Int] = []) {
        self.command = command
        self.score = score
        self.titleMatchOffsets = titleMatchOffsets
    }
}

/// Fuzzy-ranks the command registry for the Cmd+K palette. Headless and deterministic so
/// the ranking is unit-tested independently of the AppKit palette (PLAN.md §M3 "fuzzy
/// search over every action … recents on top").
public enum CommandMatcher {
    /// Rank `commands` for `query`.
    ///
    /// An empty query returns every command with the most-recently-run first (then registry
    /// order) — the palette's resting state. A non-empty query keeps only subsequence matches
    /// (title preferred, keywords as a lower-scoring fallback), sorted by score, with recency
    /// and registry order as tie-breakers.
    ///
    /// `recents` is newest-first command ids (see the app's recents store).
    public static func search(
        _ query: String,
        in commands: [Command],
        recents: [String] = []
    ) -> [CommandMatch] {
        let recencyRank = Dictionary(
            uniqueKeysWithValues: recents.enumerated().map { ($0.element, $0.offset) }
        )
        let trimmed = query.trimmingCharacters(in: .whitespaces)

        if trimmed.isEmpty {
            return commands
                .map { CommandMatch(command: $0, score: 0) }
                .sorted { lhs, rhs in
                    orderByRecencyThenIndex(lhs.command, rhs.command, recencyRank, commands)
                }
        }

        let scored: [CommandMatch] = commands.compactMap { command in
            score(command, query: trimmed)
        }
        return scored.sorted { lhs, rhs in
            if lhs.score != rhs.score { return lhs.score > rhs.score }
            return orderByRecencyThenIndex(lhs.command, rhs.command, recencyRank, commands)
        }
    }

    // MARK: - Scoring

    /// The best subsequence match of `query` against a command: its title first (carrying
    /// highlight offsets), then each keyword (a flat penalty, no offsets). `nil` if nothing
    /// matched. A recency-independent score so the ordering is stable to test.
    private static func score(_ command: Command, query: String) -> CommandMatch? {
        if let title = subsequenceScore(query: query, in: command.title) {
            return CommandMatch(
                command: command,
                score: title.score,
                titleMatchOffsets: title.offsets
            )
        }
        var best: Int?
        for keyword in command.keywords {
            if let match = subsequenceScore(query: query, in: keyword) {
                // A keyword hit is worth less than any title hit, and shorter/closer keywords
                // beat sprawling ones.
                let value = match.score - keywordPenalty
                best = max(best ?? Int.min, value)
            }
        }
        return best.map { CommandMatch(command: command, score: $0, titleMatchOffsets: []) }
    }

    /// A keyword match always ranks below a title match of the same query.
    private static let keywordPenalty = 1000

    /// Greedy left-to-right subsequence match with fzf-style bonuses: word-boundary starts
    /// and consecutive runs score well, gaps cost a little, and a full prefix is rewarded so
    /// "co" ranks "Copy" over "Close Tab". Returns `nil` when `query` is not a subsequence.
    private static func subsequenceScore(query: String, in target: String) -> (
        score: Int,
        offsets: [Int]
    )? {
        let queryChars = Array(query.lowercased())
        let targetChars = Array(target.lowercased())
        guard !queryChars.isEmpty, queryChars.count <= targetChars.count else { return nil }

        var offsets: [Int] = []
        var score = 0
        var queryIndex = 0
        var previousMatch = -2

        for (targetIndex, character) in targetChars.enumerated() where queryIndex < queryChars.count {
            guard character == queryChars[queryIndex] else { continue }

            score += 1
            if isBoundary(targetChars, targetIndex) {
                score += boundaryBonus
            }
            if targetIndex == previousMatch + 1 {
                score += consecutiveBonus
            } else if previousMatch >= 0 {
                // Penalize the gap we skipped, but never below the base match value.
                score -= min(gapPenalty, targetIndex - previousMatch - 1)
            }
            offsets.append(targetIndex)
            previousMatch = targetIndex
            queryIndex += 1
        }

        guard queryIndex == queryChars.count else { return nil }
        if targetChars.starts(with: queryChars) { score += prefixBonus }
        return (score, offsets)
    }

    private static let boundaryBonus = 10
    private static let consecutiveBonus = 5
    private static let gapPenalty = 3
    private static let prefixBonus = 15

    /// A target character starts a "word": the first character, or one preceded by a
    /// separator (space, punctuation) — the natural place a user's typing anchors.
    private static func isBoundary(_ chars: [Character], _ index: Int) -> Bool {
        guard index > 0 else { return true }
        let previous = chars[index - 1]
        return previous == " " || previous == "-" || previous == "_" || previous == "." || previous == "/"
    }

    // MARK: - Ordering helpers

    /// Tie-break: a more-recently-run command first, else the registry's own order.
    private static func orderByRecencyThenIndex(
        _ lhs: Command,
        _ rhs: Command,
        _ recencyRank: [String: Int],
        _ commands: [Command]
    ) -> Bool {
        let lhsRecency = recencyRank[lhs.id]
        let rhsRecency = recencyRank[rhs.id]
        if lhsRecency != rhsRecency {
            // A present rank (recent) sorts before a missing one; smaller rank = more recent.
            return (lhsRecency ?? Int.max) < (rhsRecency ?? Int.max)
        }
        let lhsIndex = commands.firstIndex { $0.id == lhs.id } ?? 0
        let rhsIndex = commands.firstIndex { $0.id == rhs.id } ?? 0
        return lhsIndex < rhsIndex
    }
}
