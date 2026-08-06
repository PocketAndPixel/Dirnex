import Foundation

/// GFM tables (PLAN.md §M18 ▸ Slice 1).
///
/// The one block that cannot be recognized from its own first line: `| a | b |` is a table header
/// only if the line *under* it is a delimiter row, and is an ordinary paragraph otherwise. So this
/// is asked with two lines in hand, which is also why it is asked before the paragraph gatherer
/// gets to swallow the header.
///
/// A table's cells hold unparsed inline source, like every other text in the model — links and code
/// spans inside a cell are the inline pass's business, and it has one definition of them.
enum MarkdownTableParser {
    /// Take the table starting at `start`, and answer the line after it. `nil` when there is none —
    /// which is also how `MarkdownBlockParser.startsBlock` asks whether a paragraph ends here.
    static func take(from lines: [String], at start: Int) -> (MarkdownTable, Int)? {
        guard start + 1 < lines.count else { return nil }
        guard MarkdownLine.indentation(of: lines[start]) < 4 else { return nil }
        let header = cells(in: lines[start])
        guard header.count > 1 || lines[start].contains("|") else { return nil }
        guard let alignments = alignments(in: lines[start + 1]),
              alignments.count == header.count
        else { return nil }
        var rows: [[String]] = []
        var index = start + 2
        while index < lines.count, isRow(lines[index]) {
            rows.append(cells(in: lines[index]))
            index += 1
        }
        return (MarkdownTable(header: header, alignments: alignments, rows: rows), index)
    }

    /// Whether a line still belongs to the table body. A blank line ends it, and so does anything
    /// that opens a block of its own — a table immediately followed by a heading is ordinary.
    private static func isRow(_ line: String) -> Bool {
        guard !MarkdownLine.isBlank(line), MarkdownLine.indentation(of: line) < 4 else {
            return false
        }
        return line.contains("|")
    }

    /// The delimiter row's alignments, or `nil` when this line is not one.
    ///
    /// Every cell must be a run of `-` with an optional `:` at either end. That strictness is the
    /// whole gate: without it any two consecutive lines containing a pipe would become a table, and
    /// prose with a `|` in it is common in a file manager's own documentation.
    private static func alignments(in line: String) -> [MarkdownTable.Alignment]? {
        guard MarkdownLine.indentation(of: line) < 4, line.contains("-") else { return nil }
        var result: [MarkdownTable.Alignment] = []
        for cell in cells(in: line) {
            let text = cell.trimmingCharacters(in: .whitespaces)
            let left = text.hasPrefix(":")
            let right = text.hasSuffix(":")
            let dashes = text.dropFirst(left ? 1 : 0).dropLast(right && text.count > 1 ? 1 : 0)
            guard !dashes.isEmpty, dashes.allSatisfy({ $0 == "-" }) else { return nil }
            switch (left, right) {
            case (true, true): result.append(.center)
            case (true, false): result.append(.left)
            case (false, true): result.append(.right)
            case (false, false): result.append(.none)
            }
        }
        return result.isEmpty ? nil : result
    }

    /// Split a row on unescaped pipes, dropping the optional leading and trailing one.
    ///
    /// The escape is the reason this is a scan rather than a `split(separator:)`: `\|` is how a
    /// table cell carries a pipe, and it is not rare — an argument list or a shell snippet in a
    /// cell needs it. A pipe inside a **code span** is left to the inline pass and does *not*
    /// survive this split, which is a known limit rather than an oversight: the row structure has
    /// to be decided before anything inside a cell is read.
    static func cells(in line: String) -> [String] {
        var cells: [String] = []
        var current = ""
        var escaped = false
        for character in MarkdownLine.content(of: MarkdownLine.trimmingTrailingWhitespace(line)) {
            if escaped {
                // The backslash is consumed for a pipe and kept for anything else: `\|` is how a
                // cell carries a pipe, and every other escape belongs to the inline pass, which
                // has not run yet and still needs to see its backslash.
                if character != "|" { current.append("\\") }
                current.append(character)
                escaped = false
            } else if character == "\\" {
                escaped = true
            } else if character == "|" {
                cells.append(current)
                current = ""
            } else {
                current.append(character)
            }
        }
        if escaped { current.append("\\") }
        cells.append(current)
        if cells.first?.trimmingCharacters(in: .whitespaces).isEmpty == true { cells.removeFirst() }
        if cells.last?.trimmingCharacters(in: .whitespaces).isEmpty == true { cells.removeLast() }
        return cells.map { $0.trimmingCharacters(in: .whitespaces) }
    }
}
