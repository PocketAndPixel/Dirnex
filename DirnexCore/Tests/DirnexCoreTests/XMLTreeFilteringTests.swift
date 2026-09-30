import Foundation
import Testing

@testable import DirnexCore

/// Narrowing an XML tree to what contains some text: names, values, or both.
@Suite("XMLTree filtering")
struct XMLTreeFilteringTests {
    private static let project = """
    <Project Sdk="Microsoft.NET.Sdk">
      <PropertyGroup>
        <TargetFramework>net8.0</TargetFramework>
        <Title>Fish &amp; Chips</Title>
      </PropertyGroup>
      <ItemGroup>
        <PackageReference Include="Serilog" Version="3.1.1" />
        <Note>Serilog <b>rocks</b></Note>
      </ItemGroup>
    </Project>
    """

    private func filtered(
        _ query: String,
        in scope: TreeFilterScope = .keysAndValues,
        text: String = project
    ) throws -> (tree: XMLTree, filter: TreeFilter) {
        let tree = try #require(XMLTree.parse(text))
        let filter = try #require(tree.filter(matching: query, in: scope))
        return (tree, filter)
    }

    /// The rows a filtered tree lists, depth first, indented a space a level.
    private func shown(_ tree: XMLTree, _ filter: TreeFilter) -> [String] {
        var lines: [String] = []
        func walk(_ values: [Int], depth: Int) {
            for value in values {
                lines.append(String(repeating: " ", count: depth) + tree.keyLabel(of: value).text)
                walk(tree.children(of: value, filteredBy: filter), depth: depth + 1)
            }
        }
        walk(tree.topLevelValues(filteredBy: filter), depth: 0)
        return lines
    }

    @Test("a name matches, with the way down to it, and an element that matched keeps its rows")
    func names() throws {
        let (tree, filter) = try filtered("packagereference")
        #expect(filter.matchCount == 1)
        #expect(shown(tree, filter) == [
            "Project", " ItemGroup", "  PackageReference", "   @Include", "   @Version"
        ])
    }

    @Test("an attribute's value matches under its element, and a leaf's text matches the leaf")
    func values() throws {
        let (tree, filter) = try filtered("net8")
        #expect(shown(tree, filter) == ["Project", " PropertyGroup", "  TargetFramework"])

        let attribute = try filtered("3.1.1")
        #expect(shown(attribute.tree, attribute.filter) == [
            "Project", " ItemGroup", "  PackageReference", "   @Version"
        ])
    }

    @Test("references are read before matching, so the text a row shows is the text searched")
    func decodedText() throws {
        let (tree, filter) = try filtered("fish & chips")
        #expect(shown(tree, filter) == ["Project", " PropertyGroup", "  Title"])
        #expect(try filtered("&amp;").filter.matchCount == 0)
    }

    @Test("the picker narrows the search to names or to values")
    func scopes() throws {
        #expect(try filtered("serilog", in: .keys).filter.matchCount == 0)
        let values = try filtered("serilog", in: .values)
        #expect(shown(values.tree, values.filter) == [
            "Project", " ItemGroup", "  PackageReference", "   @Include", "  Note", "   #text"
        ])
        let names = try filtered("include", in: .keys)
        #expect(names.filter.matchCount == 1)
        #expect(try filtered("include", in: .values).filter.matchCount == 0)
    }

    @Test("an element holding elements has no text of its own to match, and #text is not a name")
    func noTextOfItsOwn() throws {
        #expect(try filtered("rocks").filter.matchCount == 1)
        #expect(try filtered("text", in: .keys).filter.matchCount == 0)
    }

    @Test("a query outside ASCII reads each text it checks")
    func unicode() throws {
        let text = #"<r><имя язык="Русский">Панорама</имя></r>"#
        #expect(try filtered("русск", text: text).filter.matchCount == 1)
        #expect(try filtered("ПАНОРАМА", text: text).filter.matchCount == 1)
        #expect(try filtered("ИМЯ", in: .keys, text: text).filter.matchCount == 1)
    }

    @Test("a cancelled filter answers nothing")
    func cancelled() throws {
        let tree = try #require(XMLTree.parse(Self.project))
        #expect(tree.filter(matching: "a", in: .keysAndValues) { true } == nil)
    }

    @Test("a filtered tree opens the way down to a match, and not the matched element's own rows")
    func opening() throws {
        let (tree, filter) = try filtered("packagereference")
        let root = tree.roots[0]
        let items = tree.child(2, of: root)
        #expect(tree.initialExpansion(rowBudget: 100, filteredBy: filter) == [root, items])
    }
}
