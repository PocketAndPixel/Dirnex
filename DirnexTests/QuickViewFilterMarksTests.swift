import AppKit
import DirnexCore
import Testing

@testable import Dirnex

/// What the table and the tree mark once filtered (2026-09-15): where the query lies in a cell, in find
/// yellow, only in the part of it the filter read, and only in the columns the picker reads. Where a
/// query lies in a text is `DirnexCore`'s (`FilterQuery.occurrences`), held there to what the filters
/// keep; what is left is how a cell draws it and which cells are asked.
@Suite("Quick View filter marks")
@MainActor
struct QuickViewFilterMarksTests {
    // MARK: - A cell's line

    @Test("a mark lands where the text sits once its line breaks are drawn as spaces")
    func lineBreaks() {
        let line = QuickViewTableCell.line(
            of: "a\n\nbcd\nbc",
            marking: FilterQuery("BC"),
            within: nil
        )
        #expect(line.text == "a bcd bc")
        #expect(line.marks == [NSRange(location: 2, length: 2), NSRange(location: 6, length: 2)])
    }

    @Test("a mark is counted in the UTF-16 units an attributed string counts")
    func utf16Offsets() {
        let text = "\u{1F600} \u{41F}\u{430}\u{43D}\u{43E}\u{440}\u{430}\u{43C}\u{430} name"
        let name = QuickViewTableCell.line(of: text, marking: FilterQuery("NAME"), within: nil)
        #expect(name.marks == [NSRange(location: 12, length: 4)])
        let word = QuickViewTableCell.line(
            of: text,
            marking: FilterQuery("\u{43D}\u{43E}\u{440}"),
            within: nil
        )
        #expect(word.marks == [NSRange(location: 5, length: 3)])
    }

    @Test("only the part of a value the filter read is marked, and only its first stretch")
    func searchedPart() {
        let quoted = "\"xa\""
        let inner = quoted.index(after: quoted.startIndex)..<quoted.index(before: quoted.endIndex)
        #expect(
            QuickViewTableCell.line(of: quoted, marking: FilterQuery("a\""), within: nil).marks.count == 1
        )
        #expect(
            QuickViewTableCell.line(of: quoted, marking: FilterQuery("a\""), within: inner).marks.isEmpty
        )
        #expect(QuickViewTableCell.line(of: quoted, marking: FilterQuery("xa"), within: inner).marks
            == [NSRange(location: 1, length: 2)])

        let length = QuickViewTableCell.markedLength
        let near = String(repeating: "x", count: length - 6) + "needle"
        let far = String(repeating: "x", count: length) + "needle"
        #expect(QuickViewTableCell.line(of: near, marking: FilterQuery("needle"), within: nil).marks
            == [NSRange(location: length - 6, length: 6)])
        #expect(
            QuickViewTableCell.line(of: far, marking: FilterQuery("needle"), within: nil).marks.isEmpty
        )
    }

    // MARK: - The tree

    @Test("the tree marks the query in the key or the value that matched, and nothing else")
    func treeMarks() async throws {
        let fixture = try await QuickViewJSONFilterFixtures.tree()
        defer { fixture.cleanup() }
        let surface = fixture.surface
        let outline = surface.outlineView
        try await QuickViewJSONFilterFixtures.type("es20", into: surface)
        #expect(
            QuickViewJSONFilterFixtures.rows(surface) == ["compilerOptions {3}", "target \"ES2022\""]
        )
        #expect(Self.marks(outline, row: 0, column: 0).isEmpty)
        #expect(Self.marks(outline, row: 1, column: 0).isEmpty)
        #expect(Self.marks(outline, row: 1, column: 1) == ["ES20"])

        try await QuickViewJSONFilterFixtures.type("RICT", into: surface)
        #expect(QuickViewJSONFilterFixtures.rows(surface) == ["compilerOptions {3}", "strict true"])
        #expect(Self.marks(outline, row: 1, column: 0) == ["rict"])
        #expect(Self.marks(outline, row: 1, column: 1).isEmpty)

        // A matched container's contents are shown, and matched nothing.
        try await QuickViewJSONFilterFixtures.type("paths", into: surface)
        #expect(Self.marks(outline, row: 1, column: 0) == ["paths"])
        try outline.expandItem(#require(outline.item(atRow: 1)))
        #expect(QuickViewJSONFilterFixtures.rows(surface)[2] == "@/* [1]")
        #expect(Self.marks(outline, row: 2, column: 0).isEmpty)
        #expect(Self.marks(outline, row: 2, column: 1).isEmpty)

        try await QuickViewJSONFilterFixtures.type("", into: surface)
        for row in 0..<outline.numberOfRows {
            #expect(Self.marks(outline, row: row, column: 0).isEmpty)
            #expect(Self.marks(outline, row: row, column: 1).isEmpty)
        }
    }

    @Test("the picker decides whether a match is marked in the keys, the values or both")
    func treeScopes() async throws {
        let fixture = try await Self.tree(#"{"name": "my name", "other": "x"}"#)
        defer { fixture.cleanup() }
        let surface = fixture.surface
        let outline = surface.outlineView
        try await QuickViewJSONFilterFixtures.type("NAME", into: surface)
        #expect(QuickViewJSONFilterFixtures.rows(surface) == ["name \"my name\""])
        #expect(Self.marks(outline, row: 0, column: 0) == ["name"])
        #expect(Self.marks(outline, row: 0, column: 1) == ["name"])

        try await QuickViewJSONFilterFixtures.choose(.keys, in: surface)
        #expect(Self.marks(outline, row: 0, column: 0) == ["name"])
        #expect(Self.marks(outline, row: 0, column: 1).isEmpty)

        try await QuickViewJSONFilterFixtures.choose(.values, in: surface)
        #expect(Self.marks(outline, row: 0, column: 0).isEmpty)
        #expect(Self.marks(outline, row: 0, column: 1) == ["name"])
    }

    /// A member whose key matched is a match, so its value's cell is asked too — and the quotes drawn
    /// around a string are not text the filter read.
    @Test("the quotes the tree draws around a string are never marked")
    func treeQuotes() async throws {
        let fixture = try await Self.tree(#"{"a\"": "xa"}"#)
        defer { fixture.cleanup() }
        let surface = fixture.surface
        try await QuickViewJSONFilterFixtures.type("a\"", into: surface)
        #expect(QuickViewJSONFilterFixtures.rows(surface) == ["a\" \"xa\""])
        #expect(Self.marks(surface.outlineView, row: 0, column: 0) == ["a\""])
        #expect(Self.marks(surface.outlineView, row: 0, column: 1).isEmpty)
    }

    /// Measured before it was written: a `labelColor` attribute stays dark on a selected row, where a
    /// label's own `textColor` turns white, so the unmarked text must carry no color.
    @Test("a mark is black on find yellow, and the rest of the text keeps the label's color")
    func markColors() async throws {
        let fixture = try await QuickViewJSONFilterFixtures.tree()
        defer { fixture.cleanup() }
        let surface = fixture.surface
        try await QuickViewJSONFilterFixtures.type("es20", into: surface)
        let cell = try #require(surface.outlineView.view(atColumn: 1, row: 1, makeIfNecessary: true)
            as? NSTableCellView)
        let label = try #require(cell.textField)
        let text = label.attributedStringValue
        #expect(text.string == "\"ES2022\"")
        #expect(label.textColor == SyntaxTheme.string)
        let quote = text.attributes(at: 0, effectiveRange: nil)
        #expect(quote[.foregroundColor] == nil)
        #expect(quote[.backgroundColor] == nil)
        let mark = text.attributes(at: 1, effectiveRange: nil)
        #expect(mark[.backgroundColor] as? NSColor == NSColor.findHighlightColor)
        #expect(mark[.foregroundColor] as? NSColor == NSColor.black)
    }

    // MARK: - The table

    @Test("the table marks the query in each cell holding it, and clearing takes the marks away")
    func tableMarks() async throws {
        let fixture = try await QuickViewTableFilterFixtures.table(
            QuickViewTableFilterFixtures.sample
        )
        defer { fixture.cleanup() }
        let surface = fixture.surface
        let table = surface.tableView
        try await QuickViewTableFilterFixtures.type("CREATE", into: surface)
        #expect(QuickViewTableFilterFixtures.column(surface, 1) == ["cv/create", "attach/create"])
        for row in 0..<2 {
            #expect(Self.marks(table, row: row, column: 0).isEmpty)
            #expect(Self.marks(table, row: row, column: 1) == ["create"])
            #expect(Self.marks(table, row: row, column: 2).isEmpty)
        }

        try await QuickViewTableFilterFixtures.type("", into: surface)
        for row in 0..<table.numberOfRows {
            for column in 0..<table.numberOfColumns {
                #expect(Self.marks(table, row: row, column: column).isEmpty)
            }
        }
    }

    @Test("with a column picked, only that column is marked")
    func tableColumn() async throws {
        let fixture = try await QuickViewTableFilterFixtures.table(
            "label,code,elapsed\nx,500,500\ny,200,100\n"
        )
        defer { fixture.cleanup() }
        let surface = fixture.surface
        let table = surface.tableView
        try await QuickViewTableFilterFixtures.type("500", into: surface)
        #expect(Self.marks(table, row: 0, column: 2) == ["500"])
        #expect(Self.marks(table, row: 0, column: 3) == ["500"])

        try await QuickViewTableFilterFixtures.choose(column: 1, in: surface)
        #expect(QuickViewTableFilterFixtures.column(surface, 1) == ["x"])
        #expect(Self.marks(table, row: 0, column: 2) == ["500"])
        #expect(Self.marks(table, row: 0, column: 3).isEmpty)
    }

    // MARK: - Fixtures

    /// The runs of the cell at `row` and `column` drawn as a match.
    static func marks(_ view: NSTableView, row: Int, column: Int) -> [String] {
        guard let cell = view.view(atColumn: column, row: row, makeIfNecessary: true) as? NSTableCellView,
              let text = cell.textField?.attributedStringValue
        else { return [] }
        var marked: [String] = []
        text.enumerateAttribute(
            .backgroundColor,
            in: NSRange(location: 0, length: text.length)
        ) { value, range, _ in
            if value != nil { marked.append((text.string as NSString).substring(with: range)) }
        }
        return marked
    }

    /// A JSON file of `contents` in a tree, as `QuickViewJSONFilterFixtures.tree` opens its own.
    static func tree(
        _ contents: String,
        function: String = #function
    ) async throws -> QuickViewJSONFilterFixtures.Fixture {
        let tree = try TempDirectory()
        let preview = try await QuickViewTableFixtures.loaded(
            try tree.write("sample.json", contents: contents),
            function: function
        )
        return QuickViewJSONFilterFixtures.Fixture(
            preview: preview,
            surface: try #require(preview.treeSurface),
            tree: tree
        )
    }
}
