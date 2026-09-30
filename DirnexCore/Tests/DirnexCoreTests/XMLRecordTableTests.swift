import Foundation
import Testing

@testable import DirnexCore

/// An XML file whose root holds a list of like elements, as a table — and the files that stay a tree.
@Suite("XMLTree record tables")
struct XMLRecordTableTests {
    private func table(_ text: String, isTruncated: Bool = false) throws -> DelimitedTable {
        let tree = try #require(XMLTree.parse(text, isTruncated: isTruncated))
        return try #require(tree.recordTable())
    }

    /// A namespaced root of like records, one field nested, one hyphenated, one empty.
    @Test("records of child elements are a table, a column a name in the order names first appear")
    func childElements() throws {
        let parsed = try table("""
        <Books xmlns="http://example.com/library">
          <Book>
            <Isbn>0001</Isbn>
            <Shelf-Code>B-0001</Shelf-Code>
            <Authors>
              <Author><AuthorId>42</AuthorId></Author>
            </Authors>
          </Book>
          <Book>
            <Shelf-Code>B-0002</Shelf-Code>
            <Isbn>0002</Isbn>
            <Authors/>
          </Book>
        </Books>
        """)
        #expect(parsed.hasHeaderRow)
        #expect((0..<3).map(parsed.title(ofColumn:)) == [
            "Isbn", "Shelf-Code", "Authors"
        ])
        #expect(parsed.rowCount == 2)
        #expect(parsed.values(ofRow: 0) == [
            "0001",
            "B-0001",
            "<Authors><Author><AuthorId>42</AuthorId></Author>"
                + "</Authors>"
        ])
        #expect(parsed.values(ofRow: 1) == ["0002", "B-0002", ""])
    }

    /// Android's string resources, 28 files of them on this Mac.
    @Test("attributes are @ columns, and a record's own text is #text")
    func attributesAndText() throws {
        let parsed = try table("""
        <resources>
          <string name="app_name">Market</string>
          <string name="ok" translatable="false">OK</string>
          <string name="cancel">Cancel &amp; go</string>
        </resources>
        """)
        #expect((0..<3).map(parsed.title(ofColumn:)) == ["@name", "#text", "@translatable"])
        #expect(parsed.values(ofRow: 1) == ["ok", "OK", "false"])
        #expect(parsed.values(ofRow: 2) == ["cancel", "Cancel & go", ""])
    }

    /// Seen live on an Android `values-uk.xml`: the sentence went missing and a column held `%s`.
    @Test(
        "a record whose text sits beside elements is its whole content as #text, with no column per element"
    )
    func mixedContentRecord() throws {
        let parsed = try table("""
        <resources xmlns:xliff="urn:oasis:names:tc:xliff:document:1.2">
          <string name="ok">OK</string>
          <string name="share">Share with <xliff:g id="APP">%s</xliff:g>
          </string>
        </resources>
        """)
        #expect(parsed.columnCount == 2)
        #expect(parsed.values(ofRow: 0) == ["ok", "OK"])
        #expect(parsed.values(ofRow: 1) == ["share", #"Share with <xliff:g id="APP">%s</xliff:g>"#])
    }

    @Test("a child holding no text is its attributes, and a name a record repeats takes the first")
    func attributeOnlyAndRepeats() throws {
        let parsed = try table("""
        <deps>
          <dep><Required type="1" name="a"/><url>one</url><url>two</url></dep>
          <dep><Required type="2" name="b"/><url>three</url></dep>
        </deps>
        """)
        #expect(parsed.values(ofRow: 0) == [#"type="1" name="a""#, "one"])
        #expect(parsed.values(ofRow: 1) == [#"type="2" name="b""#, "three"])
    }

    @Test("a column is numeric when every cell that is not empty reads as a number")
    func numericColumns() throws {
        let parsed = try table("""
        <r>
          <i n="1" m="1" z=""><t>x</t></i>
          <i n="2.5" m="two" z=""><t>y</t></i>
          <i n="" m="3"><t>z</t></i>
        </r>
        """)
        #expect(parsed.numericColumns == [true, false, false, false])
    }

    @Test("a record the read limit cut is left out")
    func cutRecord() throws {
        let parsed = try table(
            "<r>\n<i a=\"1\"/>\n<i a=\"2\"/>\n<i a=\"3\"><b>par",
            isTruncated: true
        )
        #expect(parsed.rowCount == 2)
    }

    @Test(
        "one record, records of more than one name, text at the root, or too little in common stay a tree"
    )
    func staysATree() throws {
        let trees = [
            "<r><i a=\"1\"/></r>",
            "<r><i a=\"1\"/><j a=\"2\"/></r>",
            "<r>text<i a=\"1\"/><i a=\"2\"/></r>",
            "<r><i a=\"1\"/><i b=\"2\"/><i c=\"3\"/><i d=\"4\"/></r>",
            "<r><i/><i/></r>",
            "<r a=\"1\"/>",
            "<a><i x=\"1\"/><i x=\"2\"/></a><b/>"
        ]
        for text in trees {
            let tree = try #require(XMLTree.parse(text))
            #expect(tree.recordTable() == nil, "\(text) should stay a tree")
        }
    }

    @Test("more columns than the limit stay a tree")
    func columnLimit() throws {
        let tree = try #require(XMLTree.parse(#"<r><i a="1" b="2"/><i a="3" b="4"/></r>"#))
        #expect(tree.recordTable(columnLimit: 2) != nil)
        #expect(tree.recordTable(columnLimit: 1) == nil)
    }
}
