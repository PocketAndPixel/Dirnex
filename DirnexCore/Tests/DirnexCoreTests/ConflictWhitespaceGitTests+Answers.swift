import Foundation
import Testing

@testable import DirnexCore

/// What git says about the triples `ConflictWhitespaceGitTests` asks about: its plain merge, its own
/// comparisons, and each conflict as `git diff -w` reads it.
extension ConflictWhitespaceGitTests {
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
                    /// With long markers, for reading the conflicts back.
                    func merged(_ style: GitMergeOracle.Style) throws -> [UInt8] {
                        try oracle.merged(
                            base: triple.base,
                            yours: triple.yours,
                            theirs: triple.theirs,
                            style: style,
                            markerSize: markerSize
                        )
                    }
                    let labels = try conflicts(in: merged(.diff3))
                        .filter { $0.yours != $0.theirs }
                        .map { try label($0, oracle: oracle) }
                    return try Answer(
                        triple: triple,
                        // Markers of git's own length, as `GitMergeOracle.rendered` writes them.
                        zdiff3: oracle.merged(
                            base: triple.base,
                            yours: triple.yours,
                            theirs: triple.theirs,
                            style: .zdiff3
                        ),
                        yoursChanges: oracle.changes(from: triple.base, to: triple.yours),
                        theirsChanges: oracle.changes(from: triple.base, to: triple.theirs),
                        labels: labels
                    )
                }
                lock.withLock { results[index] = answer }
            } }
        }
        return try results.map { try #require($0).get() }
    }

    /// A conflict's three sections as git wrote them, each line with its break.
    struct Sections {
        var yours: [UInt8] = []
        var base: [UInt8] = []
        var theirs: [UInt8] = []
    }

    /// Every conflict in git's `--diff3` output, read by its long markers. A marker ends in CRLF when
    /// the lines around it do.
    static func conflicts(in output: [UInt8]) -> [Sections] {
        func marker(_ character: Character, _ label: String) -> [UInt8] {
            Array((String(repeating: character, count: markerSize) + " " + label).utf8)
        }
        let start = marker("<", "O")
        let base = marker("|", "B")
        let middle = Array(String(repeating: "=", count: markerSize).utf8)
        let end = marker(">", "T")
        var conflicts: [Sections] = []
        var current: Sections?
        var section: WritableKeyPath<Sections, [UInt8]> = \.yours
        for line in output.split(separator: UInt8(ascii: "\n"), omittingEmptySubsequences: false).dropLast(
        ) {
            let bare = Array(line.last == UInt8(ascii: "\r") ? line.dropLast() : line)
            switch bare {
            case start: current = Sections(); section = \.yours
            case base: section = \.base
            case middle: section = \.theirs
            case end:
                if let current { conflicts.append(current) }
                current = nil
            default: current?[keyPath: section] += Array(line) + [UInt8(ascii: "\n")]
            }
        }
        return conflicts
    }

    /// What `git diff -w` says whitespace explains in a conflict, as `ConflictWhitespace` labels it.
    static func label(_ sections: Sections, oracle: GitMergeOracle) throws -> ConflictWhitespace.Kind? {
        if try oracle.sameButForWhitespace(sections.yours, sections.theirs) {
            return .sidesDifferOnlyInWhitespace
        }
        if try oracle.sameButForWhitespace(sections.yours, sections.base) {
            return .yoursOnlyWhitespace
        }
        if try oracle.sameButForWhitespace(sections.theirs, sections.base) {
            return .theirsOnlyWhitespace
        }
        return nil
    }
}
