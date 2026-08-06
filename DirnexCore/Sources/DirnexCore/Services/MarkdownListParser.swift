import Foundation

/// Bullet and numbered lists (PLAN.md §M18 ▸ Slice 1).
///
/// The one construct in the block pass that is genuinely recursive, and the reason the parser takes
/// `[String]` rather than a cursor into one buffer: an item's content is *dedented* by its own
/// marker width and handed back to `MarkdownBlockParser`, which is what makes a list nest, hold a
/// code sample inside a step, and carry two paragraphs in one item — all without a second copy of
/// any block rule.
///
/// The column an item's content starts at is therefore the whole game. It is measured, not assumed
/// to be two: `1. ` and `- ` differ, `10. ` differs again, and a nested list is only nested because
/// it is indented past its parent's content column.
enum MarkdownListParser {
    /// What opens an item, and where its content begins.
    struct Marker: Equatable {
        let isOrdered: Bool
        /// `-`, `*`, `+` for a bullet; `.` or `)` for a number. A change of delimiter starts a
        /// *new* list rather than continuing this one — which is how two lists are written back to
        /// back with no paragraph between them.
        let delimiter: Character
        let number: Int
        /// Columns from the start of the line to the item's content. What every *following* line of
        /// the item is dedented by.
        let contentColumn: Int
        /// The first line's text, with the marker and its padding already off.
        ///
        /// Carried here rather than derived by the reader, and that is not a convenience: dedenting
        /// the marker line by `contentColumn` would strip *whitespace*, find a `-` in the way, and
        /// hand the line back unchanged — so the item's content would be the line that opened it,
        /// and parsing it would open the same item again, forever. Taking the remainder is also the
        /// argument that the recursion terminates: an item's content is strictly shorter than the
        /// line it came from.
        let body: String
        /// Whether the marker is alone on its line, which an empty item is allowed to be.
        let isEmpty: Bool
    }

    /// The marker opening `line`, or `nil` when it opens no item.
    static func marker(in line: some StringProtocol) -> Marker? {
        let indent = MarkdownLine.indentation(of: line)
        guard indent < 4 else { return nil }
        let content = MarkdownLine.content(of: line)
        guard let first = content.first else { return nil }
        var width = 0
        var isOrdered = false
        var delimiter = first
        var number = 1
        if "-*+".contains(first) {
            width = 1
        } else if first.isNumber {
            let digits = content.prefix(while: \.isNumber)
            // CommonMark's ceiling, and it earns its place: without it a line starting with a long
            // number reads as a list item whose marker is most of a year.
            guard digits.count <= 9 else { return nil }
            guard let punctuation = content.dropFirst(digits.count).first,
                  punctuation == "." || punctuation == ")"
            else { return nil }
            width = digits.count + 1
            number = Int(digits) ?? 1
            delimiter = punctuation
            isOrdered = true
        } else {
            return nil
        }
        let rest = content.dropFirst(width)
        guard rest.isEmpty || rest.first == " " || rest.first == "\t" else { return nil }
        let spaces = MarkdownLine.indentation(of: rest)
        // One space is the usual case; two to four indent the content further. Five or more is a
        // marker followed by an *indented code block*, so the content column stays at one space and
        // the surplus stays in the body where the block parser will read it as code.
        let padding = rest.isEmpty || spaces > 4 ? 1 : spaces
        let body = spaces > 4
            ? String(rest.dropFirst())
            : String(MarkdownLine.content(of: rest))
        return Marker(
            isOrdered: isOrdered,
            delimiter: delimiter,
            number: number,
            contentColumn: indent + width + padding,
            body: body,
            isEmpty: MarkdownLine.isBlank(rest)
        )
    }

    /// Whether a list starting here may interrupt a paragraph.
    ///
    /// Two carve-outs, both CommonMark's and both defending real prose: an **empty** item may not
    /// interrupt (a line of `-` under text is a setext heading, not a bullet), and an ordered list
    /// may only interrupt when it starts at **1** — otherwise `it was 1985. a good year`, wrapped
    /// onto its own line, becomes a list numbered from 1985.
    static func interruptsParagraph(_ lines: [String], at index: Int) -> Bool {
        guard let marker = marker(in: lines[index]), !marker.isEmpty else { return false }
        return !marker.isOrdered || marker.number == 1
    }

    /// Take the whole list starting at `start`, and answer the line after it.
    static func take(from lines: [String], at start: Int) -> (MarkdownList, Int)? {
        guard let first = marker(in: lines[start]) else { return nil }
        var reader = Reader(lines: lines, index: start, opening: first)
        return reader.run()
    }

    private struct Reader {
        let lines: [String]
        var index: Int
        let opening: Marker
        var items: [MarkdownListItem] = []
        /// Set by a blank line that turns out to have content after it — the definition of a loose
        /// list, which is a property of the list and not of the item that happened to carry it.
        var isLoose = false

        mutating func run() -> (MarkdownList, Int)? {
            while index < lines.count, let marker = continuingMarker() {
                takeItem(marker)
            }
            guard !items.isEmpty else { return nil }
            let list = MarkdownList(
                isOrdered: opening.isOrdered,
                start: opening.number,
                isTight: !isLoose,
                items: items
            )
            return (list, index)
        }

        /// The marker at the cursor, provided it continues *this* list rather than starting one of
        /// its own kind beside it.
        private func continuingMarker() -> Marker? {
            guard let marker = marker(in: lines[index]) else { return nil }
            guard marker.isOrdered == opening.isOrdered,
                  marker.delimiter == opening.delimiter
            else { return nil }
            return marker
        }

        private mutating func takeItem(_ marker: Marker) {
            var content = [marker.body]
            index += 1
            var blanks = 0
            while index < lines.count {
                let line = lines[index]
                if MarkdownLine.isBlank(line) {
                    blanks += 1
                    index += 1
                    continue
                }
                if MarkdownLine.indentation(of: line) >= marker.contentColumn {
                    if blanks > 0 { isLoose = true }
                    content.append(contentsOf: Array(repeating: "", count: blanks))
                    blanks = 0
                    content.append(MarkdownLine.removingIndent(marker.contentColumn, from: line))
                    index += 1
                    continue
                }
                // Lazy continuation: an unindented line that simply continues the item's paragraph.
                // Only while nothing has interrupted it — a blank line ends the item, and after one
                // an unindented line belongs to whatever comes next.
                if blanks == 0, MarkdownListParser.marker(in: line) == nil,
                   !MarkdownBlockParser.startsBlock(lines, at: index) {
                    content.append(line)
                    index += 1
                    continue
                }
                break
            }
            // A blank line *between* items makes the list loose; one at the end of the last item is
            // just the gap before the next block and says nothing.
            if blanks > 0, index < lines.count, continuingMarker() != nil { isLoose = true }
            items.append(item(from: content))
        }

        /// One item's content, with its task checkbox taken off the front if it has one.
        private func item(from content: [String]) -> MarkdownListItem {
            var lines = content
            var task: MarkdownTaskState?
            if let first = lines.first, let (state, rest) = Self.taskMarker(in: first) {
                task = state
                lines[0] = rest
            }
            return MarkdownListItem(task: task, blocks: MarkdownBlockParser.blocks(in: lines))
        }

        /// `[ ] `, `[x] ` or `[X] ` at the head of an item.
        static func taskMarker(in line: String) -> (MarkdownTaskState, String)? {
            let content = MarkdownLine.content(of: line)
            guard content.first == "[" else { return nil }
            let box = content.dropFirst()
            guard let state = box.first.flatMap(state(for:)) else { return nil }
            let rest = box.dropFirst()
            guard rest.first == "]" else { return nil }
            let tail = rest.dropFirst()
            guard tail.isEmpty || tail.first == " " || tail.first == "\t" else { return nil }
            return (state, String(tail.dropFirst(tail.isEmpty ? 0 : 1)))
        }

        private static func state(for character: Character) -> MarkdownTaskState? {
            switch character {
            case " ": .unchecked
            case "x", "X": .checked
            default: nil
            }
        }
    }
}
