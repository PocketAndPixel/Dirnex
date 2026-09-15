import Foundation
import Testing

@testable import DirnexCore

/// Filtering a JSON tree: what matches in each scope, which rows a filtered tree lists, and which of
/// them it opens — a match with the way down to it, and a matched container with its contents closed.
@Suite("JSONDocument filtering")
struct JSONDocumentFilteringTests {
    private static let config = """
    {
      "compilerOptions": {
        "target": "ES2022",
        "strict": true,
        "lib": ["ES2022", "DOM"],
        "ratio": 1.10
      },
      "include": ["src"],
      "extra": null
    }
    """

    private func document(_ text: String) throws -> JSONDocument {
        try #require(JSONDocument.parse(text))
    }

    private func filter(
        _ document: JSONDocument,
        _ query: String,
        in scope: JSONFilterScope = .keysAndValues
    ) throws -> JSONFilter {
        try #require(document.filter(matching: query, in: scope))
    }

    /// The tree a filter leaves, as `key` or `[index]` per shown value in row order, indented by depth,
    /// every shown container walked whether or not it would be open.
    private func shown(_ document: JSONDocument, _ filter: JSONFilter) -> [String] {
        var lines: [String] = []
        func walk(_ values: [Int], depth: Int) {
            for value in values {
                let label = document.key(of: value) ?? "[\(document.position(of: value))]"
                lines.append(String(repeating: " ", count: depth) + label)
                walk(document.children(of: value, filteredBy: filter), depth: depth + 1)
            }
        }
        walk(document.topLevelValues(filteredBy: filter), depth: 0)
        return lines
    }

    // MARK: - Matching

    @Test(
        "a value matches by its key or its text, ignoring case, and is shown with the way down to it"
    )
    func keysAndValues() throws {
        let parsed = try document(Self.config)
        let matched = try filter(parsed, "TARGET")
        #expect(matched.matchCount == 1)
        #expect(shown(parsed, matched) == ["compilerOptions", " target"])

        let byValue = try filter(parsed, "src")
        #expect(shown(parsed, byValue) == ["include", " [0]"])
    }

    @Test("the picker narrows the search to keys or to values")
    func scopes() throws {
        let parsed = try document(#"{"name": "target", "target": "x"}"#)
        let root = parsed.roots[0]
        let both = try filter(parsed, "target")
        #expect(both.matchCount == 2)
        let keys = try filter(parsed, "target", in: .keys)
        #expect(keys.isMatch(parsed.child(1, of: root)))
        #expect(!keys.isMatch(parsed.child(0, of: root)))
        let values = try filter(parsed, "target", in: .values)
        #expect(values.isMatch(parsed.child(0, of: root)))
        #expect(!values.isMatch(parsed.child(1, of: root)))
    }

    @Test(
        "a number, true, false and null match as the file writes them, and a container has no text"
    )
    func scalarsAsWritten() throws {
        let parsed = try document(Self.config)
        #expect(try filter(parsed, "1.10").matchCount == 1)
        #expect(try filter(parsed, "1.1", in: .values).matchCount == 1)
        #expect(try filter(parsed, "null").matchCount == 1)
        #expect(try filter(parsed, "TRUE").matchCount == 1)
        #expect(try filter(parsed, "{", in: .values).matchCount == 0)
    }

    @Test(
        "a key or a string with an escape is read before it is matched, and case is ignored beyond ASCII"
    )
    func escapesAndUnicode() throws {
        // The escape spelled in pieces, so nothing on its way into this file can read it early.
        let escapedE = "\\" + "u00e9"
        let parsed = try document(#"{"k\"ey": "caf"# + escapedE + #"", "place": "ПАНОРАМА"}"#)
        #expect(try filter(parsed, #"k"e"#, in: .keys).matchCount == 1)
        #expect(try filter(parsed, "café", in: .values).matchCount == 1)
        #expect(try filter(parsed, "CAFÉ").matchCount == 1)
        #expect(try filter(parsed, "панорама").matchCount == 1)
        #expect(try filter(parsed, "u00e9").matchCount == 0)
    }

    @Test("an empty query matches every value")
    func emptyQuery() throws {
        let parsed = try document(Self.config)
        let everything = try filter(parsed, "")
        #expect(everything.matchCount == parsed.valueCount)
    }

    @Test("a cancelled filter answers nothing")
    func cancellation() throws {
        let parsed = try document(Self.config)
        #expect(parsed.filter(matching: "a", isCancelled: { true }) == nil)
    }

    // MARK: - The tree a filter leaves

    @Test("a matched container keeps everything inside it, and only the way down to a match opens")
    func containerKeepsItsContents() throws {
        let parsed = try document(Self.config)
        let matched = try filter(parsed, "lib", in: .keys)
        #expect(shown(parsed, matched) == ["compilerOptions", " lib", "  [0]", "  [1]"])
        let options = parsed.child(0, of: parsed.roots[0])
        #expect(parsed.initialExpansion(rowBudget: 100, filteredBy: matched) == [options])
    }

    @Test("a matched container with a match inside it opens, showing all of its contents")
    func matchInsideAMatch() throws {
        let parsed = try document(Self.config)
        let matched = try filter(parsed, "e", in: .keys)
        let options = parsed.child(0, of: parsed.roots[0])
        #expect(matched.isMatch(options))
        #expect(shown(parsed, matched).prefix(7) == [
            "compilerOptions", " target", " strict", " lib", "  [0]", "  [1]", " ratio"
        ])
        #expect(parsed.initialExpansion(rowBudget: 100, filteredBy: matched).first == options)
    }

    @Test("a match deep in a big array opens the way down to it, and nothing else")
    func deepMatch() throws {
        let entries = (0..<500).map { #"{"id": \#($0)}"# }.joined(separator: ",")
        let parsed = try document(
            #"{"items": [\#(entries), {"id": 500, "name": "needle"}], "x": 1}"#
        )
        let matched = try filter(parsed, "needle")
        #expect(shown(parsed, matched) == ["items", " [500]", "  name"])
        let items = parsed.child(0, of: parsed.roots[0])
        let entry = parsed.child(500, of: items)
        #expect(parsed.initialExpansion(rowBudget: 10, filteredBy: matched) == [items, entry])
    }

    @Test("with several roots, the ones holding no match are left out")
    func severalRoots() throws {
        let parsed = try document("{\"a\": 1}\n{\"b\": 2}\n{\"a\": 3}")
        let matched = try filter(parsed, "a", in: .keys)
        #expect(shown(parsed, matched) == ["[0]", " a", "[2]", " a"])
    }

    @Test("with no filter, every child is listed and the tree opens as it always did")
    func noFilter() throws {
        let parsed = try document(Self.config)
        let options = parsed.child(0, of: parsed.roots[0])
        #expect(parsed.children(of: options, filteredBy: nil) == parsed.children(of: options))
        #expect(parsed.topLevelValues(filteredBy: nil) == parsed.topLevelValues)
        #expect(parsed.initialExpansion(rowBudget: 100, filteredBy: nil)
            == parsed.initialExpansion(rowBudget: 100))
    }
}
