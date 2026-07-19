import Foundation
import Testing

@testable import DirnexCore

@Suite("CommandMatcher")
struct CommandMatcherTests {
    /// A small, order-controlled fixture so ranking assertions don't depend on the real
    /// catalog's evolving contents.
    private let commands = [
        Command(
            id: "file.copy",
            title: "Copy to Other Panel",
            category: .file,
            keywords: ["duplicate"]
        ),
        Command(id: "file.closeTab", title: "Close Tab", category: .file),
        Command(id: "file.newFolder", title: "New Folder", category: .file, keywords: ["mkdir"]),
        Command(id: "edit.undo", title: "Undo", category: .edit)
    ]

    @Test("an empty query returns every command in registry order")
    func emptyQueryReturnsAll() {
        let results = CommandMatcher.search("", in: commands)
        #expect(results.map(\.command.id) == commands.map(\.id))
    }

    @Test("an empty query floats recents to the top, preserving order for the rest")
    func emptyQueryHonorsRecents() {
        let results = CommandMatcher.search(
            "",
            in: commands,
            recents: ["edit.undo", "file.newFolder"]
        )
        #expect(
            results.map(\.command.id) == [
                "edit.undo",
                "file.newFolder",
                "file.copy",
                "file.closeTab"
            ]
        )
    }

    @Test("a query keeps only subsequence matches")
    func filtersToSubsequenceMatches() {
        let results = CommandMatcher.search("undo", in: commands)
        #expect(results.map(\.command.id) == ["edit.undo"])
    }

    @Test("a prefix match outranks a scattered subsequence match")
    func prefixBeatsScatter() {
        // "co" is a prefix of "Copy…" and a scattered match inside "Close Tab" (C…o).
        let results = CommandMatcher.search("co", in: commands)
        #expect(results.first?.command.id == "file.copy")
        #expect(results.map(\.command.id).contains("file.closeTab"))
    }

    @Test("a title match outranks a keyword-only match")
    func titleBeatsKeyword() {
        // "new" matches the title "New Folder" and nothing else here.
        let byTitle = CommandMatcher.search("new", in: commands)
        #expect(byTitle.first?.command.id == "file.newFolder")

        // "duplicate" only matches file.copy's keyword — it should still surface it.
        let byKeyword = CommandMatcher.search("duplicate", in: commands)
        #expect(byKeyword.map(\.command.id) == ["file.copy"])
    }

    @Test("recency breaks ties between equally-scored matches")
    func recencyBreaksTies() {
        let pair = [
            Command(id: "a.rename", title: "Rename", category: .file),
            Command(id: "b.remove", title: "Remove", category: .file)
        ]
        // "re" is a prefix of both → equal score; recents decides.
        let results = CommandMatcher.search("re", in: pair, recents: ["b.remove"])
        #expect(results.map(\.command.id) == ["b.remove", "a.rename"])
    }

    @Test("title matches report the character offsets that matched, for highlighting")
    func reportsMatchOffsets() {
        let results = CommandMatcher.search("cop", in: commands)
        let match = results.first { $0.command.id == "file.copy" }
        #expect(match?.titleMatchOffsets == [0, 1, 2])
    }

    @Test("a non-matching query yields nothing")
    func noMatch() {
        #expect(CommandMatcher.search("zzzz", in: commands).isEmpty)
    }

    @Test("matching is case-insensitive")
    func caseInsensitive() {
        #expect(CommandMatcher.search("UNDO", in: commands).first?.command.id == "edit.undo")
    }
}
