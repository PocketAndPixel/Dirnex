import Foundation
import Testing

@testable import DirnexCore

/// Class and ER diagrams on the page, and the front matter any diagram may open with (PLAN.md §M39 ▸
/// Slice 14). The security claims are `MermaidRendererTests`' own, asked of the two new emitters:
/// what reached a tag, against a closed set.
@Suite("Mermaid class, ER and front matter rendering")
struct MermaidClassRenderTests {
    private func fence(_ body: String) -> String {
        MarkdownDocument.render("```mermaid\n\(body)\n```", options: MarkdownRenderOptions()).html
    }

    private static let classSample = """
    classDiagram
        namespace Zoo {
            class Animal~T~ {
                <<abstract>>
                +int age$
                +isMammal()* bool
            }
        }
        Animal "1" <|-- "*" Duck : is a
        Duck *-- Wing
        Duck o-- Pond
        Duck ..> Water
        Duck --() Swimmer
        Duck --> Duck : again
        note for Duck "quacks<br>loudly"
        class Duck {
            &lt;script&gt;alert(1)&lt;/script&gt;
        }
        click Duck href "javascript:alert(1)"
    """

    private static let erSample = """
    erDiagram
        subgraph Sales
            CUSTOMER ||--o{ ORDER : places
        end
        ORDER |o..|{ LINE : "contains <b>"
        CUSTOMER {
            string id PK "the &lt;key&gt;"
            string name
        }
        Sales ||--|| LEDGER : posts
        style ORDER fill:#f00
    """

    // MARK: - Drawn

    @Test("a class fence draws, with its members, markers and notes")
    func classDraws() {
        let output = fence(Self.classSample)
        #expect(output.contains("mermaid-class"))
        #expect(!output.contains("<pre>"))
        #expect(output.contains(">Animal&lt;T&gt;<"))
        #expect(output.contains(">«abstract»<"))
        #expect(output.contains("mm-class-static"))
        #expect(output.contains("mm-class-abstract"))
        #expect(output.contains(">+isMammal() : bool<"))
        #expect(output.contains("mm-marker-hollow"))
        #expect(output.contains("mm-marker-filled"))
        #expect(output.contains(">quacks<"))
        #expect(output.contains(">loudly<"))
        #expect(output.contains(">Zoo<"))
        // The click is named under the drawing, not followed.
        #expect(output.contains("mermaid-note"))
        #expect(output.contains("click"))
    }

    @Test("an ER fence draws its tables, crow's feet and subgraphs")
    func erDraws() {
        let output = fence(Self.erSample)
        #expect(output.contains("mermaid-er"))
        #expect(!output.contains("<pre>"))
        #expect(output.contains(">CUSTOMER<"))
        #expect(output.contains(">PK<"))
        #expect(output.contains(">the &lt;key&gt;<"))
        #expect(output.contains("mm-marker-line"))
        #expect(output.contains(">Sales<"))
        #expect(output.contains("mm-edge-dotted"))
        #expect(output.contains("style"))
    }

    @Test("every element and attribute in a class or ER diagram is one the emitters chose")
    func closedSets() {
        let elements: Set<String> = [
            "figure", "figcaption", "svg", "polyline", "polygon", "rect", "circle", "line", "text"
        ]
        let attributes: Set<String> = [
            "class", "viewBox", "xmlns", "role", "points", "fill", "x", "y", "width", "height",
            "rx", "cx", "cy", "r", "x1", "y1", "x2", "y2", "text-anchor", "dominant-baseline"
        ]
        for output in [fence(Self.classSample), fence(Self.erSample)] {
            #expect(!output.contains("<script"))
            #expect(!output.contains("<b>"))
            for tag in MermaidRendererTests.tags(in: output) {
                #expect(elements.contains(tag.name), "unexpected element <\(tag.name)>")
                for attribute in tag.attributes {
                    #expect(attributes.contains(attribute), "unexpected attribute \(attribute)")
                }
            }
        }
    }

    @Test("the emitters write no color")
    func noColors() {
        for output in [fence(Self.classSample), fence(Self.erSample)] {
            let svg = MermaidRendererTests.body(of: output)
            #expect(!svg.contains("style="))
            #expect(!svg.contains("#"))
            #expect(!svg.lowercased().contains("rgb("))
        }
    }

    @Test("a class or ER fence with nothing in it falls back and names itself")
    func emptyFallsBack() {
        #expect(
            MermaidRenderer.render("classDiagram\n%% nothing", options: MarkdownRenderOptions()) == nil
        )
        #expect(MermaidRenderer.unsupportedType(in: "erDiagram") == "erDiagram")
    }

    // MARK: - Front matter

    @Test("front matter's title is drawn above the diagram and the rest is skipped")
    func frontMatterTitle() {
        let output = fence("""
        ---
        title: Order <example>
        config:
          theme: dark
          title: not this one
        ---
        erDiagram
            CUSTOMER ||--o{ ORDER : places
        """)
        #expect(output.contains("<p class=\"mermaid-title\">Order &lt;example&gt;</p><svg"))
        #expect(!output.contains("not this one"))
        #expect(!output.contains("theme"))
    }

    @Test("a fence that draws today draws the same under front matter with no title")
    func frontMatterChangesNothingElse() {
        let plain = fence("graph TD\nA --> B")
        let configured = fence("---\nconfig:\n  look: classic\n---\ngraph TD\nA --> B")
        #expect(plain == configured)
        #expect(!plain.contains("mermaid-title"))
    }

    @Test(
        "an unsupported type under front matter is named by its own word, and an open block by ---"
    )
    func frontMatterFallback() {
        #expect(
            MermaidRenderer.unsupportedType(in: "---\ntitle: Plan\n---\ngantt\ntitle A") == "gantt"
        )
        let unclosed = fence("---\ntitle: Plan\ngraph TD\nA --> B")
        #expect(unclosed.contains("<pre>"))
        #expect(MermaidRenderer.unsupportedType(in: "---\ntitle: Plan\ngraph TD\nA --> B") == "---")
    }

    @Test("a title's quoting and comments are YAML's")
    func titleSpellings() {
        func title(_ line: String) -> String? {
            MermaidFrontMatter.split("---\n\(line)\n---\ngraph TD\nA").title
        }
        #expect(title("title: Plain words") == "Plain words")
        #expect(title("title: \"Quoted: \\\"yes\\\"\"") == "Quoted: \"yes\"")
        #expect(title("title: 'It''s'") == "It's")
        #expect(title("title: Learn C# # a comment") == "Learn C#")
        #expect(title("title:") == nil)
        #expect(title("  title: indented") == nil)
        #expect(MermaidFrontMatter.split("\n\n---\ntitle: After blank lines\n---\ngraph TD").title
            == "After blank lines")
        #expect(MermaidFrontMatter.split("graph TD\n---\ntitle: x\n---").title == nil)
    }
}
