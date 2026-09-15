import Foundation
import Testing

@testable import DirnexCore

/// What a JSON value reads as in the preview: its path, its text cut to a cell, the value written out
/// again for the strip and ⌘C, and which containers a tree opens with.
@Suite("JSONDocument text")
struct JSONDocumentTextTests {
    private func document(_ text: String) throws -> JSONDocument {
        try #require(JSONDocument.parse(text))
    }

    // MARK: - Paths

    @Test("a path names keys with dots, other keys in brackets, and elements by index")
    func paths() throws {
        let parsed = try document(
            #"{"compilerOptions": {"paths": {"@/*": ["./src/*"]}}, "my key": [0, {"имя": 1}]}"#
        )
        let root = parsed.roots[0]
        let alias = parsed.child(0, of: parsed.child(0, of: parsed.child(0, of: root)))
        #expect(parsed.path(of: root) == "$")
        #expect(parsed.path(of: parsed.child(0, of: alias)) == #"$.compilerOptions.paths["@/*"][0]"#)
        let spaced = parsed.child(1, of: root)
        #expect(parsed.path(of: spaced) == #"$["my key"]"#)
        let name = parsed.child(0, of: parsed.child(1, of: spaced))
        #expect(parsed.path(of: name) == #"$["my key"][1].имя"#)
    }

    @Test("with several roots, each is an element of the file")
    func pathsWithSeveralRoots() throws {
        let parsed = try document("{\"a\":1}\n{\"a\":{\"b\":2}}")
        let inner = parsed.child(0, of: parsed.child(0, of: parsed.roots[1]))
        #expect(parsed.path(of: inner) == "$[1].a.b")
        #expect(parsed.path(of: parsed.roots[0]) == "$[0]")
    }

    @Test("a key holding a quote or a line break is escaped inside its brackets")
    func escapedPathKey() throws {
        let parsed = try document(#"{"say \"hi\"\n": 1, "_ok$1": 2, "1st": 3}"#)
        let root = parsed.roots[0]
        #expect(parsed.path(of: parsed.child(0, of: root)) == #"$["say \"hi\"\n"]"#)
        #expect(parsed.path(of: parsed.child(1, of: root)) == "$._ok$1")
        #expect(parsed.path(of: parsed.child(2, of: root)) == #"$["1st"]"#)
    }

    // MARK: - Writing out

    @Test("formatted text indents two spaces a level and writes keys and scalars as the file does")
    func formatted() throws {
        let parsed = try document(
            #"{"a":{"b":[1.10,"x\ny"],"e":{},"f":[]}, // note"# + "\n" + #""c":null}"#
        )
        #expect(parsed.formattedText(of: parsed.roots[0]) == """
        {
          "a": {
            "b": [
              1.10,
              "x\\ny"
            ],
            "e": {},
            "f": []
          },
          "c": null
        }
        """)
        let list = parsed.child(0, of: parsed.child(0, of: parsed.roots[0]))
        #expect(parsed.formattedText(of: parsed.child(0, of: list)) == "1.10")
    }

    @Test("compact text drops the whitespace and the comments")
    func compact() throws {
        let parsed = try document(#"{ "a" : [ 1 , 2 ] /* c */ , "b" : { } }"#)
        #expect(parsed.compactText(of: parsed.roots[0]) == #"{"a":[1,2],"b":{}}"#)
    }

    @Test("a limit cuts written text at a whole character, with an ellipsis")
    func limited() throws {
        let parsed = try document(#"["абвгд"]"#)
        #expect(parsed.compactText(of: parsed.roots[0], byteLimit: 6) == #"["аб…"#)
        #expect(parsed.compactText(of: parsed.roots[0], byteLimit: 5) == #"["а…"#)
        #expect(parsed.compactText(of: parsed.roots[0], byteLimit: 100) == #"["абвгд"]"#)
    }

    @Test("a scalar's text is cut at a whole character, escaped or not")
    func scalarTextLimit() throws {
        // The escape spelled in pieces, so nothing on its way into this file can read it early.
        let escapedE = "\\" + "u00e9"
        let parsed = try document(#"["Привет", "a"# + escapedE + #"b", 123456]"#)
        let elements = parsed.children(of: parsed.roots[0])
        #expect(parsed.scalarText(of: elements[0], byteLimit: 5) == "Пр")
        #expect(parsed.scalarText(of: elements[1], byteLimit: 2) == "a")
        #expect(parsed.scalarText(of: elements[1], byteLimit: 3) == "aé")
        #expect(parsed.scalarText(of: elements[2], byteLimit: 3) == "123")
        #expect(parsed.scalarText(of: parsed.roots[0]).isEmpty)
    }

    // MARK: - Opening a tree

    @Test("a tree lists the root's own values at its top, or every root when there are several")
    func topLevel() throws {
        let object = try document(#"{"a":1,"b":2}"#)
        #expect(object.topLevelValues == object.children(of: object.roots[0]))
        let lines = try document("[1]\n[2]")
        #expect(lines.topLevelValues == lines.roots)
        let scalar = try document("\"x\"")
        #expect(scalar.topLevelValues == scalar.roots)
        let empty = try document("{}")
        #expect(empty.topLevelValues == empty.roots)
    }

    @Test("a small document opens with every container expanded")
    func smallOpensWhole() throws {
        let parsed = try document(#"{"a": {"b": [1, 2]}, "c": 3}"#)
        let outer = parsed.child(0, of: parsed.roots[0])
        #expect(parsed.initialExpansion(rowBudget: 100) == [outer, parsed.child(0, of: outer)])
    }

    @Test("a container too big for the budget stays closed while its smaller siblings open")
    func bigStaysClosed() throws {
        let numbers = (0..<50).map(String.init).joined(separator: ",")
        let parsed = try document(#"{"big": [\#(numbers)], "small": {"x": 1}}"#)
        #expect(parsed.initialExpansion(rowBudget: 10) == [parsed.child(1, of: parsed.roots[0])])
    }

    @Test("levels open in order for as long as they fit")
    func levelsInOrder() throws {
        let parsed = try document(#"{"a": {"b": {"c": {"d": 1}}}}"#)
        let first = parsed.child(0, of: parsed.roots[0])
        let second = parsed.child(0, of: first)
        #expect(parsed.initialExpansion(rowBudget: 3) == [first, second])
    }
}
