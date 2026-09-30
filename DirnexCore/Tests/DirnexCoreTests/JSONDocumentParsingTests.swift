import Foundation
import Testing

@testable import DirnexCore

/// Reading JSON into values — what `JSONSerialization` gets wrong for a preview, the JSONC that
/// `tsconfig.json` is written in, JSON Lines, and a file cut at the read limit.
@Suite("JSONDocument parsing")
struct JSONDocumentParsingTests {
    private func document(_ text: String, isTruncated: Bool = false) throws -> JSONDocument {
        try #require(JSONDocument.parse(text, isTruncated: isTruncated))
    }

    /// Each member of an object as `key=what the file writes`.
    private func members(_ document: JSONDocument, of value: Int) -> [String] {
        document.children(of: value).map {
            "\(document.key(of: $0) ?? "-")=\(document.sourceText(of: $0))"
        }
    }

    // MARK: - Values

    /// What `JSONSerialization` returned for this text, measured before any of this was written:
    /// `alpha, mid, zeta, dup, big, f`, a single `dup`, and `1.1`.
    @Test("keys keep their order, a repeated key keeps both values, and a number keeps its digits")
    func orderRepeatsAndDigits() throws {
        let parsed = try document(
            #"{"zeta":1,"alpha":2,"mid":3,"dup":1,"dup":2,"big":12345678901234567890123,"f":1.10}"#
        )
        #expect(parsed.roots.count == 1)
        #expect(members(parsed, of: parsed.roots[0]) == [
            "zeta=1", "alpha=2", "mid=3", "dup=1", "dup=2", "big=12345678901234567890123", "f=1.10"
        ])
    }

    @Test("containers hold their values in order, each with its kind, its parent and its position")
    func structure() throws {
        let parsed = try document(#"{"a": {"b": [1, true, null, "x", -2.5e3]}, "c": []}"#)
        let root = try #require(parsed.roots.first)
        #expect(parsed.kind(of: root) == .object)
        let outer = parsed.child(0, of: root)
        #expect(parsed.key(of: outer) == "a")
        let list = parsed.child(0, of: outer)
        #expect(parsed.kind(of: list) == .array)
        let elements = parsed.children(of: list)
        #expect(elements.map { parsed.kind(of: $0) } == [.number, .boolean, .null, .string, .number])
        #expect(elements.map { parsed.scalarText(of: $0) } == ["1", "true", "null", "x", "-2.5e3"])
        #expect(parsed.key(of: elements[0]) == nil)
        #expect(parsed.parent(of: list) == outer)
        #expect(parsed.parent(of: root) == nil)
        #expect(elements.map { parsed.position(of: $0) } == [0, 1, 2, 3, 4])
        #expect(parsed.childCount(of: parsed.child(1, of: root)) == 0)
        #expect(parsed.valueCount == 9)
    }

    @Test("escapes are read in keys and strings, a surrogate pair included")
    func escapes() throws {
        // The four-hex-digit escapes spelled in pieces, so nothing on its way into this file can read
        // them early (one did: the first version of this test held the characters, not the escapes).
        let escapes = ["u00e9", "ud83d", "ude00"].map { "\\" + $0 }
        let parsed = try document(
            #"{"k\"ey": "line\nbreak "# + escapes[0] + " " + escapes[1] + escapes[2]
                + #" a\/b \\ \t"}"#
        )
        #expect(!parsed.sourceText(of: parsed.roots[0]).contains("é"))
        let member = parsed.child(0, of: parsed.roots[0])
        #expect(parsed.key(of: member) == "k\"ey")
        #expect(parsed.scalarText(of: member) == "line\nbreak é 😀 a/b \\ \t")
    }

    @Test("a lone surrogate reads as the replacement character")
    func loneSurrogate() throws {
        let parsed = try document(#"["\ud800x"]"#)
        #expect(parsed.scalarText(of: parsed.child(0, of: parsed.roots[0])) == "\u{FFFD}x")
    }

    @Test("text outside ASCII passes through keys and values unchanged")
    func unicode() throws {
        let parsed = try document(#"{"имя": "Панорама 東京"}"#)
        let member = parsed.child(0, of: parsed.roots[0])
        #expect(parsed.key(of: member) == "имя")
        #expect(parsed.scalarText(of: member) == "Панорама 東京")
    }

    // MARK: - Leniency

    @Test("comments and a comma before a closing bracket are read, the way tsconfig.json has them")
    func jsonc() throws {
        let parsed = try document("""
        {
          // Visit https://aka.ms/tsconfig to read more about this file
          "compilerOptions": {
            "target": "ES2022", /* the output */
            "strict": true,
          },
          "include": ["src",],
        }
        """)
        let root = parsed.roots[0]
        #expect(parsed.children(of: root).compactMap { parsed.key(of: $0) } == [
            "compilerOptions", "include"
        ])
        #expect(members(parsed, of: parsed.child(0, of: root)) == [
            #"target="ES2022""#, "strict=true"
        ])
        #expect(parsed.childCount(of: parsed.child(1, of: root)) == 1)
    }

    @Test("several values in a row are several roots — JSON Lines, with CRLF and blank lines")
    func jsonLines() throws {
        let parsed = try document("{\"a\":1}\r\n\r\n{\"a\":2}\n[3]\n\"four\"\n")
        #expect(parsed.roots.map { parsed.kind(of: $0) } == [.object, .object, .array, .string])
        #expect(parsed.position(of: parsed.roots[2]) == 2)
    }

    @Test("a byte-order mark before the text is not a value")
    func byteOrderMark() throws {
        let parsed = try document("\u{FEFF}{\"a\":1}")
        #expect(parsed.roots.count == 1)
    }

    @Test("NaN and Infinity, which Python's json writes, read as numbers")
    func pythonNumbers() throws {
        let parsed = try document("[NaN, Infinity, -Infinity]")
        let elements = parsed.children(of: parsed.roots[0])
        #expect(elements.map { parsed.kind(of: $0) } == [.number, .number, .number])
        #expect(elements.map { parsed.scalarText(of: $0) } == ["NaN", "Infinity", "-Infinity"])
    }

    @Test("a lone number, string or word is a document of one value")
    func scalarRoots() throws {
        for (text, kind) in [
            ("42", JSONDocument.Kind.number),
            ("\"hi\"", .string),
            ("null", .null),
            ("  true  ", .boolean)
        ] {
            let parsed = try document(text)
            #expect(parsed.roots.map { parsed.kind(of: $0) } == [kind], "\(text)")
        }
    }

    @Test("text that is not JSON this reads is refused, so it is shown as text")
    func malformed() {
        let refused = [
            "", "   \n", #"{"a" 1}"#, "[1 2]", #"{"a":1}}"#, "[1,2", #"{"a":"#, #""open"#, "tru",
            "01", "{'a': 1}", "{a: 1}", "[,]", "{,}", "/* never closed", "[1] /", "1.", "-", "1e",
            #"["\x"]"#, "truefalse", "+1", "[1] # comment"
        ]
        for text in refused {
            #expect(JSONDocument.parse(text) == nil, "\(text) should be refused")
        }
    }

    // MARK: - Limits

    @Test("a file cut at the read limit closes what was open and leaves out the number it cut")
    func truncated() throws {
        let parsed = try document(#"{"a": [1, 2, 34"#, isTruncated: true)
        #expect(parsed.isTruncated)
        let root = parsed.roots[0]
        #expect(parsed.isIncomplete(root))
        let list = parsed.child(0, of: root)
        #expect(parsed.isIncomplete(list))
        #expect(parsed.children(of: list).map { parsed.scalarText(of: $0) } == ["1", "2"])
    }

    @Test("a cut inside a string, a key, a member or a comment leaves out only what it cut")
    func truncatedShapes() throws {
        let string = try document(#"{"done": "yes", "cut": "hal"#, isTruncated: true)
        #expect(members(string, of: string.roots[0]) == [#"done="yes""#])
        let key = try document(#"{"done": 1, "ke"#, isTruncated: true)
        #expect(members(key, of: key.roots[0]) == ["done=1"])
        let afterColon = try document(#"{"done": 1, "key": "#, isTruncated: true)
        #expect(members(afterColon, of: afterColon.roots[0]) == ["done=1"])
        let comment = try document("[1, 2 /* cut", isTruncated: true)
        #expect(comment.childCount(of: comment.roots[0]) == 2)
        let lines = try document("{\"a\":1}\n{\"a\":2}\n{\"a\":", isTruncated: true)
        #expect(lines.roots.count == 3)
        #expect(lines.isIncomplete(lines.roots[2]))
        #expect(!lines.isIncomplete(lines.roots[1]))
    }

    @Test("a number at the end of a whole file is whole, and at the end of a cut one is left out")
    func numberAtTheEnd() throws {
        let whole = try document("23")
        #expect(whole.scalarText(of: whole.roots[0]) == "23")
        let cut = try document("[1, 23", isTruncated: true)
        #expect(cut.childCount(of: cut.roots[0]) == 1)
        #expect(JSONDocument.parse("23", isTruncated: true) == nil)
    }

    @Test("nesting deeper than a thread's stack reads, since the scan keeps a stack of its own")
    func deepNesting() throws {
        let depth = 100_000
        let parsed = try document(
            String(repeating: "[", count: depth) + String(repeating: "]", count: depth)
        )
        #expect(parsed.valueCount == depth)
    }

    @Test("a file of more values than the limit is refused, so it is shown as text")
    func valueLimit() {
        #expect(JSONDocument.parse("[1,2,3]", isTruncated: false, valueLimit: 4) != nil)
        #expect(JSONDocument.parse("[1,2,3,4]", isTruncated: false, valueLimit: 4) == nil)
    }
}
