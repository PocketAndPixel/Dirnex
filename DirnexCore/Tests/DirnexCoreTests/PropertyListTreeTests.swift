import Foundation
import Testing

@testable import DirnexCore

/// A property list read as its keys and values — the user's choice over generic XML — and the ones
/// that are not property lists after all.
@Suite("PropertyListTree")
struct PropertyListTreeTests {
    static let info = """
    <?xml version="1.0" encoding="UTF-8"?>
    <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
    <plist version="1.0">
    <dict>
    \t<key>CFBundleName</key>
    \t<string>Dirnex</string>
    \t<key>Build</key>
    \t<integer>412</integer>
    \t<key>Scale</key>
    \t<real>1.50</real>
    \t<key>Enabled</key>
    \t<true/>
    \t<key>Updated</key>
    \t<date>2026-09-16T10:00:00Z</date>
    \t<key>Icon</key>
    \t<data>SGVsbG8s
    \tIFdvcmxk</data>
    \t<key>Types</key>
    \t<array>
    \t\t<dict>
    \t\t\t<key>UTTypeIdentifier</key>
    \t\t\t<string>com.dirnex.locations</string>
    \t\t</dict>
    \t\t<string>Fish &amp; Chips</string>
    \t</array>
    \t<key></key>
    \t<false/>
    </dict>
    </plist>
    """

    private func plist(_ text: String = info) throws -> PropertyListTree {
        let xml = try #require(XMLTree.parse(text))
        return try #require(PropertyListTree(xml))
    }

    /// Every row, depth first, as `key value`.
    private func drawn(_ tree: PropertyListTree, from values: [Int]) -> [String] {
        values.flatMap { value in
            ["\(tree.keyLabel(of: value).text) \(tree.valueLabel(of: value).text)"]
                + drawn(tree, from: tree.children(of: value))
        }
    }

    @Test("a key and its value are one row, in the order written, each scalar typed")
    func rows() throws {
        let parsed = try plist()
        #expect(parsed.labelNoun == .key)
        #expect(drawn(parsed, from: parsed.topLevelValues) == [
            #"CFBundleName "Dirnex""#,
            "Build 412",
            "Scale 1.50",
            "Enabled true",
            "Updated 2026-09-16T10:00:00Z",
            "Icon <48656c6c 6f2c2057 6f726c64>",
            "Types [2]",
            "[0] {1}",
            #"UTTypeIdentifier "com.dirnex.locations""#,
            #"[1] "Fish & Chips""#,
            "\"\" false"
        ])
        let kinds = parsed.topLevelValues.map { parsed.kind(of: $0) }
        #expect(kinds == [.string, .integer, .real, .boolean, .date, .data, .array, .boolean])
        #expect(parsed.valueLabel(of: parsed.topLevelValues[1]).role == .number)
        #expect(parsed.valueLabel(of: parsed.topLevelValues[3]).role == .keyword)
    }

    @Test("values are numbered in the order they start, so a parent comes before its children")
    func order() throws {
        let parsed = try plist()
        for value in 0..<parsed.valueCount {
            if let parent = parsed.parent(of: value) {
                #expect(parent < value)
            }
        }
        let types = parsed.topLevelValues[6]
        #expect(parsed.children(of: types).map(parsed.position(of:)) == [0, 1])
    }

    @Test("the path is PlistBuddy's, and the strip and ⌘C read a container as its XML")
    func pathsAndText() throws {
        let parsed = try plist()
        let types = parsed.topLevelValues[6]
        let identifier = parsed.child(0, of: parsed.child(0, of: types))
        #expect(parsed.path(of: identifier) == ":Types:0:UTTypeIdentifier")
        #expect(parsed.path(of: parsed.child(1, of: types)) == ":Types:1")
        #expect(parsed.copiedText(of: identifier) == "com.dirnex.locations")
        #expect(parsed.copiedText(of: parsed.child(0, of: types)) == """
        <dict>
        \t<key>UTTypeIdentifier</key>
        \t<string>com.dirnex.locations</string>
        </dict>
        """)
        #expect(parsed.stripText(of: identifier, byteLimit: 3) == "com…")
    }

    @Test("a root that is a scalar, or an empty container, is the one row")
    func rootRows() throws {
        let scalar = try plist("<plist><string>x</string></plist>")
        #expect(drawn(scalar, from: scalar.topLevelValues) == [#": "x""#])
        #expect(scalar.path(of: scalar.topLevelValues[0]) == ":")
        let empty = try plist("<plist><dict/></plist>")
        #expect(drawn(empty, from: empty.topLevelValues) == [": {0}"])
    }

    @Test("the filter reads keys, or scalars as their rows show them")
    func filter() throws {
        let parsed = try plist()
        #expect(parsed.filter(matching: "bundle", in: .keys)?.matchCount == 1)
        #expect(parsed.filter(matching: "bundle", in: .values)?.matchCount == 0)
        #expect(parsed.filter(matching: "fish & chips", in: .values)?.matchCount == 1)
        #expect(parsed.filter(matching: "6f2c", in: .values)?.matchCount == 1)
        #expect(parsed.filter(matching: "types", in: .values)?.matchCount == 0)
        let found = try #require(parsed.filter(matching: "dirnex.locations", in: .keysAndValues))
        #expect(parsed.initialExpansion(rowBudget: 100, filteredBy: found) == [
            parsed.topLevelValues[6], parsed.child(0, of: parsed.topLevelValues[6])
        ])
    }

    @Test("what is not a property list is read as XML instead")
    func notAPropertyList() throws {
        let others = [
            "<root><dict/></root>",
            "<plist><dict><key>a</key></dict></plist>",
            "<plist><dict><string>a</string><string>b</string></dict></plist>",
            "<plist><dict><key>a</key><object/></dict></plist>",
            "<plist><string><b/></string></plist>",
            "<plist><dict/><dict/></plist>",
            "<plist>text</plist>"
        ]
        for text in others {
            let xml = try #require(XMLTree.parse(text), "\(text)")
            #expect(PropertyListTree(xml) == nil, "\(text) is not a property list")
            #expect(XMLTree.document(from: text) is XMLTree)
        }
        #expect(XMLTree.document(from: Self.info) is PropertyListTree)
    }

    @Test(
        "a dictionary the read limit cut part-way through a pair drops the key its value did not reach"
    )
    func truncated() throws {
        let xml = try #require(XMLTree.parse(
            "<plist><dict><key>a</key><string>1</string><key>b</key><str",
            isTruncated: true
        ))
        let parsed = try #require(PropertyListTree(xml))
        #expect(parsed.isTruncated)
        #expect(drawn(parsed, from: parsed.topLevelValues) == [#"a "1""#])
    }

    @Test("an array of dictionaries is a table, a column a key")
    func recordTable() throws {
        let parsed = try plist("""
        <plist><array>
        <dict><key>name</key><string>a</string><key>size</key><integer>1</integer></dict>
        <dict><key>size</key><real>2.5</real><key>name</key><string>b</string><key>tags</key><array/></dict>
        </array></plist>
        """)
        let table = try #require(parsed.recordTable())
        #expect((0..<3).map(table.title(ofColumn:)) == ["name", "size", "tags"])
        #expect(table.values(ofRow: 1) == ["b", "2.5", "<array/>"])
        #expect(table.numericColumns == [false, true, false])
        #expect(try plist().recordTable() == nil)
    }
}
