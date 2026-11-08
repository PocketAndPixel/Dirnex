import Foundation
import Testing

@testable import DirnexCore

/// What whitespace explains in a conflict, against git (PLAN.md §M37 Slice 5).
///
/// git is the check on both halves. The regions: on triples where one side changed only whitespace,
/// the merge Dirnex opens is git's plain `--zdiff3` merge byte for byte, so labelling moved nothing,
/// where git's own ignore options would have settled those conflicts. And the label: each of git's
/// `--diff3` conflicts, read whole, is labelled exactly as `git diff -w` reads its three sections.
///
/// The triples are this repository's files and short random texts, one side respaced over a stretch
/// (re-indented, tabs for spaces, trailing spaces, CRLF) and the other edited inside it. Every text
/// ends in a line break, since git ends each section of a conflict with one, and a side that lacked
/// it would read as the same as one that had it.
@Suite("ConflictWhitespace against git")
struct ConflictWhitespaceGitTests {
    typealias Triple = ThreeWayMergeGitTests.Triple

    /// What git said about one triple.
    struct Answer: Sendable {
        let triple: Triple
        let zdiff3: [UInt8]
        let yoursChanges: [LineDiff.Change]
        let theirsChanges: [LineDiff.Change]
        /// Each of git's `--diff3` conflicts whose two sides differ, in order, as `git diff -w`
        /// reads its sections.
        let labels: [ConflictWhitespace.Kind?]
    }

    static let answers: Result<[Answer], any Error> = Result {
        try answers(for: corpusTriples() + randomTriples(count: 500, seed: 0x0037_0007))
    }

    /// Longer than any line of a document that is all `=` or `<`.
    static let markerSize = 40

    @Test("with a side respaced, the regions are git's plain merge's, byte for byte")
    func regionsDidNotMove() throws {
        let answers = try Self.answers.get()
        var conflicted = 0
        var labelled = 0
        for answer in answers {
            let triple = answer.triple
            let (base, yours, theirs) = (triple.baseLines, triple.yoursLines, triple.theirsLines)
            let untrimmed = ThreeWayMerge.merge(
                base: base,
                yours: yours,
                theirs: theirs,
                yoursChanges: answer.yoursChanges,
                theirsChanges: answer.theirsChanges,
                trimsConflicts: false
            )
            let kept = GitMergeOracle.identicalConflicts(in: untrimmed, yours: yours, theirs: theirs)
            // From git's comparisons, the merge a labelled merge holds; then as the window opens it,
            // from its own, where two minimal alignments may tie.
            for (merge, ownComparisons) in [(Self.merge(answer), false), (Self.opened(triple), true)] {
                let rendered = GitMergeOracle.rendered(
                    merge.merge,
                    base: base,
                    yours: yours,
                    theirs: theirs,
                    keptByGit: kept
                )
                if ownComparisons, rendered != answer.zdiff3 {
                    #expect(Self.isTie(merge.merge, answer), "\(triple.name)")
                    continue
                }
                #expect(rendered == answer.zdiff3, "\(triple.name)")
            }
            let merge = Self.merge(answer)
            if !merge.choices.isEmpty { conflicted += 1 }
            labelled += merge.whitespace.count(where: { $0 != nil })
        }
        #expect(answers.count >= 600)
        #expect(conflicted >= 300)
        #expect(labelled >= 300)
    }

    @Test("a conflict is labelled exactly as git's -w reads its sections")
    func labelsAreGits() throws {
        let answers = try Self.answers.get()
        var kinds: [ConflictWhitespace.Kind: Int] = [:]
        var offered = 0
        for answer in answers {
            let merge = Self.merge(answer)
            #expect(merge.whitespace.map { $0?.kind } == answer.labels, "\(answer.triple.name)")
            for whitespace in merge.whitespace {
                guard let whitespace else { continue }
                kinds[whitespace.kind, default: 0] += 1
                if whitespace.combined != nil { offered += 1 }
            }
        }
        #expect(kinds[.yoursOnlyWhitespace, default: 0] >= 100, "\(kinds)")
        #expect(kinds[.theirsOnlyWhitespace, default: 0] >= 100, "\(kinds)")
        #expect(kinds[.sidesDifferOnlyInWhitespace, default: 0] >= 50, "\(kinds)")
        #expect(offered >= 150)
    }

    /// One of the cases git's ignore options were probed on, and the text the take writes for it.
    struct Probe: Sendable, CustomTestStringConvertible {
        let base: String
        let yours: String
        let theirs: String
        let both: String
        var testDescription: String { "\(yours.debugDescription) against \(theirs.debugDescription)" }
    }

    static let probes = [
        Probe(
            base: "f {\n  a\n  B\n  c\n}\n",
            yours: "f {\n    a\n    B\n    c\n}\n",
            theirs: "f {\n  a\n  B!\n  c\n}\n",
            both: "f {\n    a\n    B!\n    c\n}\n"
        ),
        Probe(
            base: "f {\n  a\n  B\n  c\n}\n",
            yours: "f {\n  a\n  B!\n  c\n}\n",
            theirs: "f {\n\ta\n\tB\n\tc\n}\n",
            both: "f {\n\ta\n\tB!\n\tc\n}\n"
        ),
        Probe(
            base: "f {\n  a  \n  B  \n  c\n}\n",
            yours: "f {\n  a\n  B\n  c\n}\n",
            theirs: "f {\n  a  \n  B!  \n  c\n}\n",
            both: "f {\n  a\n  B!\n  c\n}\n"
        ),
        Probe(
            base: "alpha\nbravo\ncharlie\n",
            yours: "alpha\r\nbravo\r\ncharlie\r\n",
            theirs: "alpha\nbravo 2\ncharlie\n",
            both: "alpha\r\nbravo 2\r\ncharlie\r\n"
        )
    ]

    @Test(
        "git's ignore options drop the whitespace edit, and the take keeps both",
        arguments: probes
    )
    func gitDropsTheWhitespaceEdit(_ probe: Probe) throws {
        var merge = TextMergeTests.merge(probe.base, probe.yours, probe.theirs)
        let edit = merge.whitespace.first??.editSide == .theirs ? probe.theirs : probe.yours
        for option in ["ignore-space-change", "ignore-all-space"] {
            let git = try Self.mergeTree(
                base: probe.base,
                yours: probe.yours,
                theirs: probe.theirs,
                option: option
            )
            #expect(String(bytes: git, encoding: .utf8) == edit, "\(option)")
        }
        try #require(merge.offers(.editWithWhitespace, forConflict: 0))
        merge.apply(TextMerge.Step(conflict: 0, choice: .editWithWhitespace))
        #expect(TextMergeTests.text(merge.result.lines) == probe.both)
    }

    // MARK: - Merges

    /// The merge Dirnex makes from git's own comparisons, which M34 holds to git's byte for byte.
    private static func merge(_ answer: Answer) -> TextMerge {
        let triple = answer.triple
        let (base, yours, theirs) = (triple.baseLines, triple.yoursLines, triple.theirsLines)
        return TextMerge(
            base: TextMergeTests.document(triple.base),
            yours: TextMergeTests.document(triple.yours),
            theirs: TextMergeTests.document(triple.theirs),
            merge: ThreeWayMerge.merge(
                base: base,
                yours: yours,
                theirs: theirs,
                yoursChanges: answer.yoursChanges,
                theirsChanges: answer.theirsChanges
            )
        )
    }

    /// The merge as the window opens it: its own comparisons, as `minimal` as git's.
    private static func opened(_ triple: Triple) -> TextMerge {
        TextMerge(
            base: TextMergeTests.document(triple.base),
            yours: TextMergeTests.document(triple.yours),
            theirs: TextMergeTests.document(triple.theirs),
            merge: ThreeWayMerge.merge(
                base: triple.baseLines,
                yours: triple.yoursLines,
                theirs: triple.theirsLines,
                options: LineDiffOptions(isMinimal: true)
            )
        )
    }

    /// Whether a merge that is not git's came from comparisons that tie with git's: the same lines
    /// removed and inserted, aligned another way.
    private static func isTie(_ merge: ThreeWayMerge, _ answer: Answer) -> Bool {
        let triple = answer.triple
        let options = LineDiffOptions(isMinimal: true)
        func counts(_ changes: [LineDiff.Change]) -> [Int] {
            [changes.reduce(0) { $0 + $1.left.count }, changes.reduce(0) { $0 + $1.right.count }]
        }
        let yours = LineDiff.compare(
            triple.baseLines,
            triple.yoursLines,
            options: options,
            placement: .lowest
        )
        let theirs = LineDiff.compare(
            triple.baseLines,
            triple.theirsLines,
            options: options,
            placement: .lowest
        )
        return (yours.changes != answer.yoursChanges || theirs.changes != answer.theirsChanges)
            && counts(yours.changes) == counts(answer.yoursChanges)
            && counts(theirs.changes) == counts(answer.theirsChanges)
    }

    /// git's merge of two branches under `-X<option>`, through `merge-tree` in a scratch repository.
    private static func mergeTree(base: String, yours: String, theirs: String, option: String) throws -> [
        UInt8
    ] {
        let oracle = try GitMergeOracle()
        defer { oracle.cleanup() }
        let repository = try oracle.tree.makeDir("repository")
        let file = repository + "/f.txt"
        @discardableResult
        func git(_ arguments: [String]) throws -> [UInt8] {
            let (status, output) = try oracle.git(
                ["-C", repository, "-c", "user.name=Dirnex", "-c", "user.email=tests@dirnex.invalid"] + arguments
            )
            try #require(status == 0, "git \(arguments) exited \(status)")
            return output
        }
        func commit(_ text: String, on branch: String, from start: String) throws {
            try git(["checkout", "-q", "-b", branch, start])
            try Data(text.utf8).write(to: URL(fileURLWithPath: file))
            try git(["commit", "-q", "-a", "-m", branch])
        }
        try git(["init", "-q", "-b", "main"])
        try Data(base.utf8).write(to: URL(fileURLWithPath: file))
        try git(["add", "f.txt"])
        try git(["commit", "-q", "-m", "base"])
        try commit(yours, on: "yours", from: "main")
        try commit(theirs, on: "theirs", from: "main")
        let tree = try git(["merge-tree", "--write-tree", "-X\(option)", "yours", "theirs"])
            .split(separator: UInt8(ascii: "\n")).first.flatMap { String(bytes: $0, encoding: .utf8) } ?? ""
        return try git(["cat-file", "-p", "\(tree):f.txt"])
    }
}
