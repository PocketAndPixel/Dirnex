import Foundation

/// Line primitives shared by the block, list and table passes (PLAN.md §M18 ▸ Slice 1).
///
/// Everything Markdown decides at block level is decided from a line's leading columns, and a
/// **tab is four columns, not one character** — so indentation is measured rather than counted, and
/// stripping it can leave part of a tab behind. That is the whole reason this is a type instead of
/// three `hasPrefix` calls: getting it wrong turns a tab-indented list into a code block.
///
/// Lines are never rewritten to make measuring easier. Expanding leading tabs once at the split
/// would be simpler and would quietly re-indent the contents of a fenced `Makefile`, where the tab
/// *is* the syntax.
enum MarkdownLine {
    static let tabWidth = 4

    /// Split `text` into lines, keeping empty ones.
    ///
    /// Split on `\.isNewline`, never on `"\n"`: a Swift `Character` is a grapheme cluster, so CRLF
    /// is **one** `Character` equal to neither `"\r"` nor `"\n"` — a `split(separator: "\n")` does
    /// not split a Windows-written file at all, and the whole file arrives as one unparseable line
    /// (docs/NOTES.md). Every `.md` written on the other OS goes through here.
    ///
    /// A **final newline terminates the last line rather than starting a new one**, so a file
    /// ending the way every file should has the number of lines it looks like it has. Without that
    /// one `dropLast`, an unclosed fence at the end of a truncated read gains a blank line of code
    /// that is not in the file.
    static func split(_ text: String) -> [String] {
        var lines = text
            .split(omittingEmptySubsequences: false, whereSeparator: \.isNewline)
            .map(String.init)
        if lines.count > 1, lines[lines.count - 1].isEmpty { lines.removeLast() }
        return lines
    }

    /// Whether the line is empty or nothing but whitespace, which is what separates blocks.
    static func isBlank(_ line: some StringProtocol) -> Bool {
        line.allSatisfy(\.isWhitespace)
    }

    /// The line's indentation in columns, with a tab advancing to the next multiple of four.
    static func indentation(of line: some StringProtocol) -> Int {
        var columns = 0
        for character in line {
            if character == "\t" {
                columns += tabWidth - (columns % tabWidth)
            } else if character == " " {
                columns += 1
            } else {
                break
            }
        }
        return columns
    }

    /// The line with its leading whitespace removed.
    static func content<S: StringProtocol>(of line: S) -> S.SubSequence {
        line.drop { $0 == " " || $0 == "\t" }
    }

    /// The line with up to `columns` of leading indentation removed, and nothing else touched.
    ///
    /// A tab that straddles the boundary is replaced by the spaces it stood for on the far side —
    /// dropping it whole would silently dedent the rest of the line by up to three columns, which
    /// inside a code block is a changed file rather than a changed layout.
    static func removingIndent(_ columns: Int, from line: some StringProtocol) -> String {
        var removed = 0
        var index = line.startIndex
        while index < line.endIndex, removed < columns {
            let character = line[index]
            if character == " " {
                removed += 1
            } else if character == "\t" {
                removed += tabWidth - (removed % tabWidth)
            } else {
                break
            }
            index = line.index(after: index)
        }
        let overshoot = max(0, removed - columns)
        return String(repeating: " ", count: overshoot) + line[index...]
    }

    /// Trailing whitespace removed — what a heading's closing `###` run and a table row both need.
    static func trimmingTrailingWhitespace(_ line: some StringProtocol) -> String {
        var result = Substring(line)
        while let last = result.last, last.isWhitespace { result = result.dropLast() }
        return String(result)
    }
}
