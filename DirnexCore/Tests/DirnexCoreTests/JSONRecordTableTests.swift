import Foundation
import Testing

@testable import DirnexCore

/// A JSON Lines file, or a JSON array of objects, as a table — and the lists that stay a tree.
@Suite("JSONDocument record tables")
struct JSONRecordTableTests {
    private func table(_ text: String, isTruncated: Bool = false) throws -> DelimitedTable {
        let document = try #require(JSONDocument.parse(text, isTruncated: isTruncated))
        return try #require(document.recordTable())
    }

    @Test("JSON Lines of objects is a table, a column for each key in the order keys first appear")
    func jsonLines() throws {
        let parsed = try table("""
        {"role": "user", "content": "Rename it"}
        {"role": "assistant", "content": "Done", "ts": 3}
        {"content": "Thanks", "role": "user"}
        """)
        #expect(parsed.hasHeaderRow)
        #expect(parsed.columnCount == 3)
        #expect((0..<3).map(parsed.title(ofColumn:)) == ["role", "content", "ts"])
        #expect(parsed.rowCount == 3)
        #expect(parsed.values(ofRow: 0) == ["user", "Rename it", ""])
        #expect(parsed.values(ofRow: 1) == ["assistant", "Done", "3"])
        #expect(parsed.values(ofRow: 2) == ["user", "Thanks", ""])
    }

    @Test("a file whose top level is an array of objects is a table too")
    func topLevelArray() throws {
        let parsed = try table("""
        [
          {"directory": "/build", "command": "cc -c a.c", "file": "a.c"},
          {"directory": "/build", "command": "cc -c b.c", "file": "b.c"}
        ]
        """)
        #expect((0..<3).map(parsed.title(ofColumn:)) == ["directory", "command", "file"])
        #expect(parsed.values(ofRow: 1) == ["/build", "cc -c b.c", "b.c"])
    }

    @Test("a nested value is its compact JSON, a string its text, and null is written out")
    func cellText() throws {
        let parsed = try table(#"""
        [{"a": {"x": [1, 2]}, "b": "q\"uote", "c": null},
         {"a": [], "b": "", "c": true}]
        """#)
        #expect(parsed.values(ofRow: 0) == [#"{"x":[1,2]}"#, "q\"uote", "null"])
        #expect(parsed.values(ofRow: 1) == ["[]", "", "true"])
    }

    @Test(
        "a column of numbers is numeric, one mixing in anything but null is not, and all-null is not"
    )
    func numericColumns() throws {
        let parsed = try table(#"""
        [{"n": 1, "m": 1, "z": null}, {"n": 2.5, "m": "two", "z": null}, {"n": null, "m": 3}]
        """#)
        #expect(parsed.numericColumns == [true, false, false])
    }

    @Test("the table sorts by value, filters and copies as a CSV does")
    func sortsFiltersAndCopies() throws {
        let parsed = try table(#"""
        [{"name": "b", "size": 10}, {"name": "a", "size": 9}, {"name": "c", "size": 100}]
        """#)
        #expect(parsed.rowOrder(sortedByColumn: 1, ascending: true) == [1, 0, 2])
        #expect(parsed.rowsMatching("C") == [false, false, true])
        #expect(parsed.tabSeparatedText(rows: [2]) == "c\t100")
        #expect(parsed.longestValueByteCount(inColumn: 1) == 3)
    }

    @Test("a repeated key keeps the last value, as JSON.parse does")
    func repeatedKey() throws {
        let parsed = try table(#"[{"a": 1, "a": 2}, {"a": 3}]"#)
        #expect(parsed.columnCount == 1)
        #expect(parsed.cell(row: 0, column: 0) == "2")
    }

    @Test("a record the read limit cut is left out")
    func truncatedRecord() throws {
        let parsed = try table("{\"a\":1}\n{\"a\":2}\n{\"a\":", isTruncated: true)
        #expect(parsed.rowCount == 2)
    }

    @Test("what is not a list of like objects stays a tree")
    func notRecords() throws {
        let refused = [
            #"{"a": 1}"#,
            #"[{"a": 1}]"#,
            #"[{"a": 1}, 2]"#,
            "[1, 2, 3]",
            "{\"a\": 1}\n[1]",
            #"[{"a": 1, "b": 2}, {"c": 3, "d": 4}, {"e": 5, "f": 6}]"#,
            "[{}, {}]",
            "\"text\""
        ]
        for text in refused {
            let document = try #require(JSONDocument.parse(text))
            #expect(document.recordTable() == nil, "\(text) should stay a tree")
        }
    }

    @Test("more keys than the column limit stays a tree")
    func columnLimit() throws {
        let document = try #require(JSONDocument.parse(#"[{"a":1,"b":2},{"a":1,"b":2}]"#))
        #expect(document.recordTable(columnLimit: 2) != nil)
        #expect(document.recordTable(columnLimit: 1) == nil)
    }
}
