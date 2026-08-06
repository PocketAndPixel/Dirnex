import Foundation
import Testing

@testable import DirnexCore

/// The block pass (PLAN.md §M18 ▸ Slice 1).
///
/// The tests are grouped by the thing that can go wrong rather than by construct, because the risk
/// here is not "does a heading parse" — it is **ordering**: three pairs of constructs open with the
/// same character, and each pair renders the document wrong in a different way when tested in the
/// wrong order.
@Suite("MarkdownBlockParser")
struct MarkdownBlockParserTests {
    private func blocks(_ text: String) -> [MarkdownBlock] {
        MarkdownBlockParser.scan(text).blocks
    }

    // MARK: - Headings

    @Test("ATX headings take their level from the hashes, and need a space after them")
    func atxHeadings() {
        #expect(blocks("# One\n") == [.heading(level: 1, text: "One")])
        #expect(blocks("###### Six\n") == [.heading(level: 6, text: "Six")])
        // Seven is not a heading, and neither is a hashtag.
        #expect(blocks("####### Seven") == [.paragraph("####### Seven")])
        #expect(blocks("#hashtag") == [.paragraph("#hashtag")])
    }

    @Test("a closing run of hashes is decoration, unless it is part of the text")
    func closingHashes() {
        #expect(blocks("## Title ##") == [.heading(level: 2, text: "Title")])
        // No space before the run, so it belongs to the word — otherwise `# C#` loses its language.
        #expect(blocks("# C#") == [.heading(level: 1, text: "C#")])
    }

    @Test("a setext underline turns the paragraph above it into a heading")
    func setextHeadings() {
        #expect(blocks("Title\n=====\n") == [.heading(level: 1, text: "Title")])
        #expect(blocks("Subtitle\n---\n") == [.heading(level: 2, text: "Subtitle")])
        // The construct M17's scanner cannot reach, because it needs the previous line.
        #expect(blocks("Two\nlines\n---") == [.heading(level: 2, text: "Two\nlines")])
    }

    @Test("`---` is a thematic break with nothing above it, and a heading with a paragraph above")
    func setextVersusThematicBreak() {
        #expect(blocks("---") == [.thematicBreak])
        #expect(blocks("\n---\n") == [.thematicBreak])
        #expect(blocks("Text\n---") == [.heading(level: 2, text: "Text")])
        // `***` and `___` have no setext form, so they are always a break.
        #expect(blocks("Text\n***") == [.paragraph("Text"), .thematicBreak])
    }

    @Test("a thematic break is tested before the list marker it starts like")
    func thematicBreakBeatsListMarker() {
        // Written the other way round, `---` reads as a bullet with no content.
        #expect(blocks("- - -") == [.thematicBreak])
        #expect(blocks("* * *") == [.thematicBreak])
    }

    // MARK: - Code

    @Test("a fence carries its info string and its body verbatim")
    func fencedCode() {
        let source = """
        ```swift
        let x = 1
        ```
        """
        #expect(blocks(source) == [.codeBlock(info: "swift", code: "let x = 1\n")])
    }

    @Test("a fence closes only on its own character, so one kind can quote the other")
    func fenceCharacters() {
        let source = """
        ~~~
        ```
        not a fence
        ```
        ~~~
        """
        #expect(blocks(source) == [.codeBlock(info: nil, code: "```\nnot a fence\n```\n")])
    }

    @Test("an unclosed fence runs to the end, which is what a truncated read hands over")
    func unclosedFence() {
        #expect(blocks("```\nstill code\n") == [.codeBlock(info: nil, code: "still code\n")])
    }

    @Test("a fence keeps nothing of its own indentation and none of the body's")
    func indentedFence() {
        let source = "  ```\n  body\n    deeper\n  ```"
        #expect(blocks(source) == [.codeBlock(info: nil, code: "body\n  deeper\n")])
    }

    @Test("four columns of indentation is a code block, and it does not keep its trailing blanks")
    func indentedCode() {
        let source = "    one\n\n    two\n\ntext"
        #expect(blocks(source) == [
            .codeBlock(info: nil, code: "one\n\ntwo\n"),
            .paragraph("text")
        ])
    }

    @Test("an indented line under a paragraph is a wrapped line, not a code block")
    func indentedContinuation() {
        // The carve-out in `startsBlock`: a hanging indent must not turn half a sentence grey.
        #expect(blocks("A sentence\n    that wrapped") == [.paragraph("A sentence\nthat wrapped")])
    }

    @Test("a tab is four columns, so one tab opens a code block")
    func tabIndentation() {
        #expect(blocks("\tcode") == [.codeBlock(info: nil, code: "code\n")])
    }

    // MARK: - Quotes and lists

    @Test("a blockquote holds blocks, and takes lazy continuation lines with it")
    func blockQuotes() {
        #expect(blocks("> # Quoted\n> body\ncontinued\n") == [
            .blockQuote([
                .heading(level: 1, text: "Quoted"),
                .paragraph("body\ncontinued")
            ])
        ])
    }

    @Test("a list's items are parsed as blocks, which is what makes one nest")
    func nestedList() {
        let source = """
        - outer
          - inner
        """
        let inner = MarkdownList(
            isOrdered: false,
            start: 1,
            isTight: true,
            items: [MarkdownListItem(blocks: [.paragraph("inner")])]
        )
        #expect(blocks(source) == [.list(MarkdownList(
            isOrdered: false,
            start: 1,
            isTight: true,
            items: [MarkdownListItem(blocks: [.paragraph("outer"), .list(inner)])]
        ))])
    }

    @Test("an ordered list keeps the number it starts at")
    func orderedStart() {
        guard case let .list(list)? = blocks("3. three\n4. four").first else {
            Issue.record("expected a list")
            return
        }
        #expect(list.isOrdered)
        #expect(list.start == 3)
        #expect(list.items.count == 2)
    }

    @Test("a change of marker starts a new list rather than continuing the old one")
    func markerChange() {
        let parsed = blocks("- a\n* b")
        #expect(parsed.count == 2)
        guard case let .list(first)? = parsed.first, case let .list(second) = parsed[1] else {
            Issue.record("expected two lists")
            return
        }
        #expect(first.items.count == 1)
        #expect(second.items.count == 1)
    }

    @Test("a blank line between items makes the list loose")
    func looseList() {
        guard case let .list(tight)? = blocks("- a\n- b").first,
              case let .list(loose)? = blocks("- a\n\n- b").first
        else {
            Issue.record("expected lists")
            return
        }
        #expect(tight.isTight)
        #expect(!loose.isTight)
    }

    @Test("a task item's checkbox comes off the front of its text")
    func taskItems() {
        guard case let .list(list)? = blocks("- [ ] open\n- [x] done\n- plain").first else {
            Issue.record("expected a list")
            return
        }
        #expect(list.items.map(\.task) == [.unchecked, .checked, nil])
        #expect(list.items[1].blocks == [.paragraph("done")])
    }

    @Test("an ordered list may only interrupt a paragraph when it starts at 1")
    func listInterruptingParagraph() {
        // Otherwise a wrapped sentence ending in a year becomes a list numbered from it.
        #expect(blocks("it was\n1985. a good year") == [.paragraph("it was\n1985. a good year")])
        #expect(blocks("text\n1. one").count == 2)
    }

    // MARK: - Front matter and references

    @Test("front matter is read as metadata rather than as a rule and a paragraph")
    func frontMatter() {
        let source = """
        ---
        title: A note
        tags: one, two
        ---

        Body.
        """
        #expect(blocks(source) == [
            .frontMatter([
                MarkdownFrontMatterEntry(key: "title", value: "A note"),
                MarkdownFrontMatterEntry(key: "tags", value: "one, two")
            ]),
            .paragraph("Body.")
        ])
    }

    @Test("a leading rule that is not front matter stays a rule")
    func notFrontMatter() {
        // The `key:` gate: without it, rule-paragraph-rule is read as metadata.
        #expect(blocks("---\nJust text\n---") == [
            .thematicBreak,
            .heading(level: 2, text: "Just text")
        ])
    }

    @Test("link definitions are collected and leave no paragraph behind")
    func linkDefinitions() {
        let scan = MarkdownBlockParser.scan("[Home]: https://example.com \"Title\"\n\nText.\n")
        #expect(scan.blocks == [.paragraph("Text.")])
        #expect(scan.references["home"] == MarkdownLinkReference(
            destination: "https://example.com",
            title: "Title"
        ))
    }

    @Test("a definition-shaped line inside a fence is code, not a definition")
    func definitionInsideFence() {
        let scan = MarkdownBlockParser.scan("```\n[a]: b\n```\n")
        #expect(scan.references.isEmpty)
        #expect(scan.blocks == [.codeBlock(info: nil, code: "[a]: b\n")])
    }

    @Test("a definition-shaped line mid-paragraph is prose, and does not split it")
    func definitionMidParagraph() {
        let scan = MarkdownBlockParser.scan("A line\n[a]: b\n")
        #expect(scan.references.isEmpty)
        #expect(scan.blocks == [.paragraph("A line\n[a]: b")])
    }

    // MARK: - Tables

    @Test("a table needs its delimiter row, and is a paragraph without one")
    func tableRequiresDelimiter() {
        #expect(blocks("| a | b |\n| - | - |\n| 1 | 2 |") == [.table(MarkdownTable(
            header: ["a", "b"],
            alignments: [.none, .none],
            rows: [["1", "2"]]
        ))])
        #expect(blocks("| a | b |\n| 1 | 2 |") == [.paragraph("| a | b |\n| 1 | 2 |")])
    }

    @Test("the delimiter row's colons are the column alignments")
    func tableAlignments() {
        guard case let .table(table)? = blocks("|a|b|c|d|\n|:-|:-:|-:|-|\n").first else {
            Issue.record("expected a table")
            return
        }
        #expect(table.alignments == [.left, .center, .right, .none])
    }

    @Test("an escaped pipe stays in the cell it was written in")
    func escapedPipe() {
        guard case let .table(table)? = blocks("| a \\| b | c |\n| - | - |\n").first else {
            Issue.record("expected a table")
            return
        }
        #expect(table.header == ["a | b", "c"])
    }

    @Test("prose containing a pipe is not a table")
    func pipeInProse() {
        #expect(blocks("use a | b\nto pipe") == [.paragraph("use a | b\nto pipe")])
    }

    // MARK: - Line endings

    @Test("CRLF splits into lines, which `split(separator:)` on a newline would not")
    func windowsLineEndings() {
        // docs/NOTES.md: CRLF is one `Character` equal to neither `\r` nor `\n`, so a naive split
        // hands the whole file back as a single unparseable line.
        #expect(blocks("# Title\r\n\r\nBody.\r\n") == [
            .heading(level: 1, text: "Title"),
            .paragraph("Body.")
        ])
    }

    @Test("an empty document parses to nothing at all")
    func empty() {
        #expect(blocks("").isEmpty)
        #expect(blocks("\n\n   \n").isEmpty)
    }
}
