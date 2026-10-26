import Foundation
import Testing

@testable import DirnexCore

/// The merge window's result against `git merge-file` (PLAN.md §M34 Slice 2): every conflict taking
/// yours, theirs, or yours then theirs has to give what git writes with `--ours`, `--theirs` and
/// `--union`, over `ThreeWayMergeGitTests`' triples and from git's own comparisons.
@Suite("TextMerge against git")
struct TextMergeGitTests {
    @Test("taking yours, theirs or both in every conflict gives git's --ours, --theirs and --union")
    func everyConflictOneWay() throws {
        let answers = try ThreeWayMergeGitTests.answers.get()
        var compared = 0
        var unionSkipped = 0
        for answer in answers {
            let triple = answer.triple
            let base = TextMergeTests.document(triple.base)
            let yours = TextMergeTests.document(triple.yours)
            let theirs = TextMergeTests.document(triple.theirs)
            let merge = ThreeWayMerge.merge(
                base: base.lines,
                yours: yours.lines,
                theirs: theirs.lines,
                yoursChanges: answer.yoursChanges,
                theirsChanges: answer.theirsChanges
            )
            let opened = TextMerge(base: base, yours: yours, theirs: theirs, merge: merge)
            // Where yours' last line, with no break, ends a conflict, taking both parts from git
            // twice. git gives that line a break even with nothing of theirs after it, where
            // `TextMerge` leaves a file's last line as it was; and git's break is CRLF when the lines
            // around it are, where `TextMerge` takes yours' common ending.
            let hasCRLF = [yours, theirs, base].contains { $0.lines.contains { $0.terminator == .crlf } }
            let breaksDiffer = merge.regions.contains { region in
                region.kind == .conflict && !region.yours.isEmpty
                    && region.yours.upperBound == yours.lines.count
                    && yours.lines.last?.terminator == LineTerminator.none
                    && (region.theirs.isEmpty || hasCRLF)
            }
            let choices: [(GitMergeOracle.Favor, TextMerge.Choice)] = [
                (.ours, .yours), (.theirs, .theirs), (.union, .yoursThenTheirs)
            ]
            for (favor, choice) in choices {
                if favor == .union, breaksDiffer {
                    unionSkipped += 1
                    continue
                }
                var chosen = opened
                for conflict in chosen.choices.indices {
                    chosen.apply(TextMerge.Step(conflict: conflict, choice: choice))
                }
                let ours = try chosen.result.encoded()
                let git = try #require(answer.favored[favor])
                #expect(Array(ours) == git, "\(triple.name) --\(favor.rawValue)")
                compared += 1
            }
        }
        // Without these the comparison could be over merges with nothing to choose. When this was
        // written, 1 990 results were compared and 44 unions were passed over.
        #expect(compared >= 1950)
        #expect(unionSkipped <= 50, "\(unionSkipped)")
    }
}
