import Foundation
import Testing

@testable import DirnexCore

/// The triples `ConflictWhitespaceGitTests` asks git about: one side respaced over a stretch and the
/// other edited inside it, either way round, and now and then both respaced.
extension ConflictWhitespaceGitTests {
    /// Each file of `LineDiffGitCorpusTests`' corpus, respaced over a stretch and edited inside it.
    static func corpusTriples() throws -> [Triple] {
        let corpus = try LineDiffGitCorpusTests.corpus()
        try #require(corpus.count > 30, "the corpus was not found")
        var rng = SeededGenerator(seed: 0x0037_0008)
        var triples: [Triple] = []
        for url in corpus {
            var text = try String(contentsOf: url, encoding: .utf8)
            if !text.hasSuffix("\n") { text += "\n" }
            var lines = text.components(separatedBy: "\n")
            lines.removeLast()
            guard lines.count > 12 else { continue }
            let start = Int.random(in: 0..<lines.count - 6, using: &rng)
            let stretch = start..<min(lines.count, start + Int.random(in: 6...25, using: &rng))
            let respaced = respace(lines, in: stretch, using: &rng)
            let edited = edit(lines, in: stretch, using: &rng)
            let again = respace(
                lines,
                in: stretch.lowerBound + 2..<min(lines.count, stretch.upperBound + 4),
                using: &rng
            )
            let name = url.lastPathComponent
            triples += [
                Triple(name: "\(name) respaced, edited", base: text, yours: respaced, theirs: edited),
                Triple(name: "\(name) edited, respaced", base: text, yours: edited, theirs: respaced),
                Triple(name: "\(name) respaced twice", base: text, yours: respaced, theirs: again)
            ]
        }
        return triples
    }

    /// Short texts over a few lines with varied indentation, trailing spaces and endings.
    static func randomTriples(count: Int, seed: UInt64) -> [Triple] {
        var rng = SeededGenerator(seed: seed)
        let texts = ["a", "b = c", "d(e)", "f"]
        func line() -> String {
            (["", "  ", "    ", "\t"].randomElement(using: &rng) ?? "")
                + (texts.randomElement(using: &rng) ?? "a")
                + (Int.random(in: 0..<5, using: &rng) == 0 ? " " : "")
        }
        return (0..<count).map { index in
            let base = (0..<Int.random(in: 1...10, using: &rng)).map { _ in line() }
            let crlf = Int.random(in: 0..<4, using: &rng) == 0
            func text(_ lines: [String]) -> String {
                lines.map { $0.hasSuffix("\r") ? $0 + "\n" : $0 + (crlf ? "\r\n" : "\n") }.joined()
            }
            func respaced() -> [String] {
                base.map { line in
                    Int.random(in: 0..<3, using: &rng) == 0 ? respace(line, using: &rng) : line
                }
            }
            func edited() -> [String] {
                var lines = base
                for _ in 0..<Int.random(in: 1...3, using: &rng) {
                    let start = Int.random(in: 0...lines.count, using: &rng)
                    let end = min(lines.count, start + Int.random(in: 0...2, using: &rng))
                    lines.replaceSubrange(start..<end, with: (0..<Int.random(in: 0...2, using: &rng)).map { _ in
                        line() + "!"
                    })
                }
                return lines
            }
            let sides = switch Int.random(in: 0..<5, using: &rng) {
            case 0, 1: (respaced(), edited())
            case 2, 3: (edited(), respaced())
            default: (respaced(), respaced())
            }
            return Triple(
                name: "random \(index)",
                base: text(base),
                yours: text(sides.0),
                theirs: text(sides.1)
            )
        }
    }

    // MARK: - Respacing and editing

    /// `lines` with one kind of whitespace changed over `stretch`, each line ending in LF unless it
    /// was made CRLF.
    private static func respace(
        _ lines: [String],
        in stretch: Range<Int>,
        using rng: inout SeededGenerator
    ) -> String {
        var lines = lines
        let mode = Int.random(in: 0..<6, using: &rng)
        for index in stretch {
            lines[index] = switch mode {
            case 0: lines[index].isEmpty ? "" : "    " + lines[index]
            case 1: lines[index].replacingOccurrences(of: "    ", with: "\t")
            case 2: lines[index].isEmpty ? "" : lines[index] + " "
            case 3: lines[index] + "\r"
            case 4: lines[index].hasPrefix("  ") ? String(lines[index].dropFirst(2)) : lines[index] + "\r"
            default: lines[index].isEmpty ? "" : "\t" + lines[index]
            }
        }
        if mode == 5 {
            // The whole file CRLF as well, which makes the whole file one conflict.
            lines = lines.map { $0.hasSuffix("\r") ? $0 : $0 + "\r" }
        }
        return lines.map { $0 + "\n" }.joined()
    }

    /// One line with its indentation, trailing space or ending changed.
    private static func respace(_ line: String, using rng: inout SeededGenerator) -> String {
        switch Int.random(in: 0..<4, using: &rng) {
        case 0: "  " + line
        case 1: line.hasPrefix("\t") ? "    " + line.dropFirst() : "\t" + line.drop { $0 == " " }
        case 2: line.hasSuffix(" ") ? String(line.dropLast()) : line + " "
        default: line + "\r"
        }
    }

    /// `lines` with one to three edits inside `stretch`: a line changed, a line added after it with
    /// its indentation, or a line removed.
    private static func edit(
        _ lines: [String],
        in stretch: Range<Int>,
        using rng: inout SeededGenerator
    ) -> String {
        var lines = lines
        var end = stretch.upperBound
        for edit in 0..<Int.random(in: 1...3, using: &rng) where end > stretch.lowerBound {
            let index = Int.random(in: stretch.lowerBound..<end, using: &rng)
            switch Int.random(in: 0..<3, using: &rng) {
            case 0:
                lines[index] += " // edited \(edit)"
            case 1:
                let indent = lines[index].prefix { $0 == " " || $0 == "\t" }
                lines.insert(String(indent) + "let added\(edit) = \(edit)", at: index + 1)
                end += 1
            default:
                lines.remove(at: index)
                end -= 1
            }
        }
        return lines.map { $0 + "\n" }.joined()
    }
}
