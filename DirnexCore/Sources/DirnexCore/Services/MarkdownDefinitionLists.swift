import Foundation

/// Definition lists, a term on one line and its definitions under it (PLAN.md §M39 ▸ Slice 7):
///
///     Apple
///     : A fruit that keeps.
///     : A company.
///
/// GitHub draws none of this, so there is no renderer to read the rules off and no corpus to score
/// them against: of 12 603 distinct `.md` files on this Mac, not one writes a definition list. The
/// rules are Pandoc's, the one written down, at the points where PHP Markdown Extra agrees with it:
///
/// - **A term is one line**, alone: the first line of what would otherwise be a paragraph, followed
///   by a definition, or by one blank line and then a definition.
/// - **A definition opens on `:`**, indented up to three spaces and followed by a space or a tab. It
///   continues lazily while its paragraph does, takes anything indented four columns after a blank
///   line, and a term may have several. A blank line before one draws its text as a paragraph.
/// - **Groups follow each other** into one list, with or without blank lines between them.
///
/// What is left out is left out because the corpus *does* hold its shape as prose. A wrapped line in
/// this repository's HISTORY.md opens with `: "conflicts"` in the middle of a paragraph, so a `:`
/// line never interrupts a paragraph and a term is never more than one line. That rules out PHP
/// Markdown Extra's several terms over one definition, which would have read every line above it as
/// a term. A paragraph's *second* line opening with `: ` is the syntax itself and reads as a
/// definition, as it does in Pandoc; HISTORY.md's is the third. Pandoc's `~` marker is left out,
/// since `~ 5 minutes` opening a line is prose.
enum MarkdownDefinitionLists {
    /// Take the definition list whose first term is the line at `start`, and answer the line after it.
    /// `nil` when that line is not a term, which is the common answer: a paragraph.
    static func take(from lines: [String], at start: Int) -> (MarkdownBlock, Int)? {
        guard isTerm(lines, at: start) else { return nil }
        var items: [MarkdownDefinitionItem] = []
        var index = start
        while index < lines.count, isTerm(lines, at: index) {
            let term = MarkdownLine.trimmingTrailingWhitespace(
                MarkdownLine.content(of: lines[index])
            )
            index += 1
            var definitions: [MarkdownDefinition] = []
            while let marker = nextMarker(in: lines, from: index) {
                let (blocks, next) = definition(in: lines, at: marker.line)
                definitions.append(MarkdownDefinition(isLoose: marker.isLoose, blocks: blocks))
                index = next
            }
            items.append(MarkdownDefinitionItem(term: term, definitions: definitions))
            index = skippingBlanks(lines, from: index)
        }
        return (.definitionList(items), index)
    }

    /// The text after a definition's `:` and the whitespace that follows it, when `line` opens one.
    static func markerBody(of line: String) -> String? {
        guard MarkdownLine.indentation(of: line) < 4 else { return nil }
        let content = MarkdownLine.content(of: line)
        guard content.first == ":" else { return nil }
        let rest = content.dropFirst()
        guard let space = rest.first, space == " " || space == "\t" else { return nil }
        return String(MarkdownLine.content(of: rest))
    }

    /// Whether the line at `index` is a term: a line that would open a paragraph, followed by a
    /// definition directly or after one blank line.
    ///
    /// The marker is looked for first, since it is the cheap test and almost every line fails it.
    private static func isTerm(_ lines: [String], at index: Int) -> Bool {
        guard nextMarker(in: lines, from: index + 1) != nil else { return false }
        let line = lines[index]
        guard !MarkdownLine.isBlank(line), MarkdownLine.indentation(of: line) < 4,
              markerBody(of: line) == nil,
              MarkdownListParser.marker(in: line) == nil,
              !MarkdownBlockParser.startsBlock(lines, at: index)
        else { return false }
        return true
    }

    /// The marker line at `index`, or after one blank line there, and whether that blank line was.
    private static func nextMarker(in lines: [String], from index: Int) -> (line: Int, isLoose: Bool)? {
        guard index < lines.count else { return nil }
        if markerBody(of: lines[index]) != nil { return (index, false) }
        guard MarkdownLine.isBlank(lines[index]), index + 1 < lines.count,
              markerBody(of: lines[index + 1]) != nil
        else { return nil }
        return (index + 1, true)
    }

    /// One definition's blocks, from the marker line at `start`, and the line after it. The same
    /// continuation as a footnote's (`MarkdownFootnotes.take`), less two lines that belong to the
    /// list: the next `:` and the next term.
    private static func definition(in lines: [String], at start: Int) -> ([MarkdownBlock], Int) {
        var content = [markerBody(of: lines[start]) ?? ""]
        var index = start + 1
        var blanks = 0
        while index < lines.count {
            let line = lines[index]
            if MarkdownLine.isBlank(line) {
                blanks += 1
                index += 1
                continue
            }
            if MarkdownLine.indentation(of: line) >= 4 {
                content.append(contentsOf: Array(repeating: "", count: blanks))
                blanks = 0
                content.append(MarkdownLine.removingIndent(4, from: line))
                index += 1
                continue
            }
            if blanks == 0, let last = content.last, !MarkdownLine.isBlank(last),
               markerBody(of: line) == nil,
               !isTerm(lines, at: index),
               !MarkdownBlockParser.startsBlock(lines, at: index) {
                content.append(line)
                index += 1
                continue
            }
            break
        }
        // Back to the first blank line, so the caller sees the gap before what comes next.
        return (MarkdownBlockParser.blocks(in: content), index - blanks)
    }

    private static func skippingBlanks(_ lines: [String], from index: Int) -> Int {
        var index = index
        while index < lines.count, MarkdownLine.isBlank(lines[index]) {
            index += 1
        }
        return index
    }
}
