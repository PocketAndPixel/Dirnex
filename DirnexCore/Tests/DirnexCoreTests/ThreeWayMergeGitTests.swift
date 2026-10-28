import Foundation
import Testing

@testable import DirnexCore

/// `ThreeWayMerge` against `git merge-file` (PLAN.md §M34 Slice 1).
///
/// The triples are this repository's own files, each edited twice the way files get edited (the
/// edits M31's corpus makes), plus short random texts over a few distinct lines, which is where
/// changes touch, overlap and tie most. git is asked for its merge in both styles, and for its own
/// comparison of each side with the base.
///
/// Two things are checked. Given git's comparisons, the merge must be git's to the byte, in both
/// styles: that is the walk, the joining and the trimming, with nothing left to chance. Given its
/// own comparisons, it must be git's except where git and `LineDiff` found two different minimal
/// alignments of the same lines, which the second test counts.
///
/// The triples are made here rather than taken from the repository's history because CI checks
/// out a single commit. The history was run once instead, recorded in PLAN.md §M34.
@Suite("ThreeWayMerge against git")
struct ThreeWayMergeGitTests {
    struct Triple: Sendable {
        let name: String
        let base: String
        let yours: String
        let theirs: String

        var baseLines: [TextLine] { TextLines.split(base) }
        var yoursLines: [TextLine] { TextLines.split(yours) }
        var theirsLines: [TextLine] { TextLines.split(theirs) }
    }

    /// What git said about one triple.
    struct Answer: Sendable {
        let triple: Triple
        let diff3: [UInt8]
        let zdiff3: [UInt8]
        let yoursChanges: [LineDiff.Change]
        let theirsChanges: [LineDiff.Change]
        /// `--zdiff3` with every conflict settled each way git can (`TextMergeGitTests`).
        let favored: [GitMergeOracle.Favor: [UInt8]]
    }

    /// git's answers for every triple, asked once for this suite and `TextMergeGitTests`, many at a
    /// time: each run of git costs about 9 ms, and there are seven per triple.
    static let answers: Result<[Answer], any Error> = Result {
        let triples = try corpusTriples() + randomTriples(count: 600, seed: 0x0034_0001)
        return try answers(for: triples)
    }

    @Test("given git's own comparisons, every merge is git's to the byte, in both styles")
    func gitComparisons() throws {
        let answers = try Self.answers.get()
        var conflicted = 0
        var trimmed = 0
        var identical = 0
        for answer in answers {
            let triple = answer.triple
            let (base, yours, theirs) = (triple.baseLines, triple.yoursLines, triple.theirsLines)
            func merge(trimming: Bool) -> ThreeWayMerge {
                ThreeWayMerge.merge(
                    base: base,
                    yours: yours,
                    theirs: theirs,
                    yoursChanges: answer.yoursChanges,
                    theirsChanges: answer.theirsChanges,
                    trimsConflicts: trimming
                )
            }
            let untrimmed = merge(trimming: false)
            let ours = GitMergeOracle.rendered(untrimmed, base: base, yours: yours, theirs: theirs)
            #expect(
                ours == answer.diff3,
                "\(triple.name) diff3: \(Self.describe(ours, answer.diff3))"
            )

            let kept = GitMergeOracle.identicalConflicts(in: untrimmed, yours: yours, theirs: theirs)
            let trimmedMerge = merge(trimming: true)
            let oursTrimmed = GitMergeOracle.rendered(
                trimmedMerge,
                base: base,
                yours: yours,
                theirs: theirs,
                keptByGit: kept
            )
            #expect(
                oursTrimmed == answer.zdiff3,
                "\(triple.name) zdiff3: \(Self.describe(oursTrimmed, answer.zdiff3))"
            )
            if !untrimmed.isClean {
                conflicted += 1
            }
            if trimmedMerge.regions.contains(where: { $0.kind == .same && $0.base.isEmpty }) {
                trimmed += 1
            }
            identical += kept.count
        }
        // Without these, a corpus whose edits stopped meeting would pass on agreement about
        // merges that never conflict, and the trimming and its one departure would go untested.
        #expect(answers.count >= 600)
        #expect(conflicted >= 200)
        #expect(conflicted <= answers.count - 100)
        #expect(trimmed >= 30)
        #expect(identical >= 1)
    }

    @Test("given its own comparisons, every merge is git's but where two minimal alignments tie")
    func ownComparisons() throws {
        let answers = try Self.answers.get()
        var ties: [String] = []
        let options = LineDiffOptions(isMinimal: true)
        for answer in answers {
            let triple = answer.triple
            let (base, yours, theirs) = (triple.baseLines, triple.yoursLines, triple.theirsLines)
            let yoursDiff = LineDiff.compare(base, yours, options: options, placement: .lowest)
            let theirsDiff = LineDiff.compare(base, theirs, options: options, placement: .lowest)
            let untrimmed = ThreeWayMerge.merge(
                base: base,
                yours: yours,
                theirs: theirs,
                yoursChanges: yoursDiff.changes,
                theirsChanges: theirsDiff.changes,
                trimsConflicts: false
            )
            let merge = ThreeWayMerge.merge(
                base: base,
                yours: yours,
                theirs: theirs,
                options: options
            )
            let ours = GitMergeOracle.rendered(
                merge,
                base: base,
                yours: yours,
                theirs: theirs,
                keptByGit: GitMergeOracle.identicalConflicts(
                    in: untrimmed,
                    yours: yours,
                    theirs: theirs
                )
            )
            guard ours != answer.zdiff3 else { continue }
            // A tie: the same lines changed, aligned another way. Both comparisons are minimal
            // (`LineDiffPropertyTests`), so a count that differs is not a tie but a bug.
            let isTie = (yoursDiff.changes != answer.yoursChanges
                || theirsDiff.changes != answer.theirsChanges)
                && Self.counts(yoursDiff.changes) == Self.counts(answer.yoursChanges)
                && Self.counts(theirsDiff.changes) == Self.counts(answer.theirsChanges)
            #expect(isTie, "\(triple.name): \(Self.describe(ours, answer.zdiff3))")
            if isTie {
                ties.append(triple.name)
            }
        }
        // Ties are the price of two searches that each stop at the first minimal answer: 28 of the
        // 678 triples when this was written, one of them a corpus file. A jump in their number
        // means the search or the placement changed.
        #expect(ties.count <= 30, "\(ties.count) ties: \(ties)")
    }

    // MARK: - The triples

    /// Lines removed and inserted, which two minimal alignments of the same pair share.
    private static func counts(_ changes: [LineDiff.Change]) -> (removed: Int, inserted: Int) {
        changes.reduce((0, 0)) { ($0.0 + $1.left.count, $0.1 + $1.right.count) }
    }

    /// Every file of `LineDiffGitCorpusTests`' corpus, edited twice: once two edits of the file
    /// itself, and once an edit and then an edit of that, where the second builds on the first.
    static func corpusTriples() throws -> [Triple] {
        let corpus = try LineDiffGitCorpusTests.corpus()
        try #require(corpus.count > 30, "the corpus was not found")
        var rng = SeededGenerator(seed: 0x0034_0002)
        var triples: [Triple] = []
        for url in corpus {
            let base = try String(contentsOf: url, encoding: .utf8)
            let name = url.lastPathComponent
            triples.append(Triple(
                name: "\(name) apart",
                base: base,
                yours: LineDiffGitCorpusTests.edit(base, using: &rng),
                theirs: LineDiffGitCorpusTests.edit(base, using: &rng)
            ))
            let yours = LineDiffGitCorpusTests.edit(base, using: &rng)
            triples.append(Triple(
                name: "\(name) built on",
                base: base,
                yours: yours,
                theirs: LineDiffGitCorpusTests.edit(yours, using: &rng)
            ))
        }
        return triples
    }

    /// Short texts over a few distinct lines, some ending in CRLF and some with no final line
    /// break. Most sides are a few edits of the base, some build on the other side, and some are
    /// unrelated to it.
    static func randomTriples(count: Int, seed: UInt64) -> [Triple] {
        var rng = SeededGenerator(seed: seed)
        return (0..<count).map { index in
            let alphabet = Int.random(in: 1...5, using: &rng)
            let crlfShare = [0, 0, 1, 3].randomElement(using: &rng) ?? 0
            func line() -> String {
                let letter = UInt8(ascii: "a") + UInt8.random(in: 0..<UInt8(alphabet), using: &rng)
                let ending = Int.random(in: 0..<4, using: &rng) < crlfShare ? "\r\n" : "\n"
                return String(UnicodeScalar(letter)) + ending
            }
            func edited(_ lines: [String]) -> [String] {
                var lines = lines
                for _ in 0..<Int.random(in: 0...3, using: &rng) {
                    let start = Int.random(in: 0...lines.count, using: &rng)
                    let end = min(lines.count, start + Int.random(in: 0...3, using: &rng))
                    let replacement = (0..<Int.random(in: 0...3, using: &rng)).map { _ in line() }
                    lines.replaceSubrange(start..<end, with: replacement)
                }
                return lines
            }
            let base = (0..<Int.random(in: 0...12, using: &rng)).map { _ in line() }
            let yours = Int.random(in: 0..<10, using: &rng) == 0
                ? (0..<Int.random(in: 0...12, using: &rng)).map { _ in line() }
                : edited(base)
            let theirs = Bool.random(using: &rng) ? edited(yours) : edited(base)
            func text(_ lines: [String]) -> String {
                // A line moved to the end keeps its break, and only some files lose the last one,
                // never leaving a lone CR, which git and `TextLines` split differently.
                guard let last = lines.last, Int.random(in: 0..<5, using: &rng) == 0 else {
                    return lines.joined()
                }
                return lines.dropLast().joined() + last.trimmingCharacters(in: .newlines)
            }
            return Triple(
                name: "random \(index)",
                base: text(base),
                yours: text(yours),
                theirs: text(theirs)
            )
        }
    }

    /// git's answers for `triples`, eight at a time, in the order given.
    static func answers(for triples: [Triple]) throws -> [Answer] {
        let lock = NSLock()
        nonisolated(unsafe) var results = [Result<Answer, any Error>?](
            repeating: nil,
            count: triples.count
        )
        DispatchQueue.concurrentPerform(iterations: 8) { worker in
            for index in stride(from: worker, to: triples.count, by: 8) { autoreleasepool {
                let triple = triples[index]
                let answer = Result<Answer, any Error> {
                    let oracle = try GitMergeOracle()
                    defer { oracle.cleanup() }
                    func merged(
                        _ style: GitMergeOracle.Style,
                        favor: GitMergeOracle.Favor? = nil
                    ) throws -> [UInt8] {
                        try oracle.merged(
                            base: triple.base,
                            yours: triple.yours,
                            theirs: triple.theirs,
                            style: style,
                            favor: favor
                        )
                    }
                    return try Answer(
                        triple: triple,
                        diff3: merged(.diff3),
                        zdiff3: merged(.zdiff3),
                        yoursChanges: oracle.changes(from: triple.base, to: triple.yours),
                        theirsChanges: oracle.changes(from: triple.base, to: triple.theirs),
                        favored: [
                            .ours: merged(.zdiff3, favor: .ours),
                            .theirs: merged(.zdiff3, favor: .theirs),
                            .union: merged(.zdiff3, favor: .union)
                        ]
                    )
                }
                lock.withLock { results[index] = answer }
            } }
        }
        return try results.map { try #require($0).get() }
    }

    /// Two outputs one after the other, for a failure message.
    private static func describe(_ ours: [UInt8], _ git: [UInt8]) -> String {
        let ours = String(bytes: ours, encoding: .utf8) ?? "\(ours)"
        let git = String(bytes: git, encoding: .utf8) ?? "\(git)"
        return "\nDirnex:\n\(ours)\ngit:\n\(git)"
    }
}
