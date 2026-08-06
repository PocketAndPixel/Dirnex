import Foundation
import Testing

@testable import DirnexCore

/// Reading a ```` ```mermaid ```` fence into a diagram (PLAN.md §M18 ▸ Slice 4).
///
/// The cases are shaped by what breaks rather than by what the grammar lists. Two families carry
/// most of them: an edge operator whose *length* changes its meaning (`--` is a link only with a
/// head, `---` is one without), and a scan that has to ignore anything inside brackets — because
/// `A[a --> b] --> C` misread is not a syntax error, it is a diagram with a node named `A[a` in it.
@Suite("Mermaid parser")
struct MermaidParserTests {
    private func flowchart(_ source: String) -> MermaidFlowchart? {
        guard case let .flowchart(chart) = MermaidParser.parse(source) else { return nil }
        return chart
    }

    // MARK: - Which diagram is this

    @Test("the header word picks the dialect, and every other type is named")
    func diagramType() {
        #expect(flowchart("graph TD\nA --> B") != nil)
        #expect(flowchart("flowchart LR\nA --> B") != nil)
        // The sequence dialect's own cases are in `MermaidSequenceParserTests`; here the claim is
        // only that the header word routes to it.
        if case .sequence = MermaidParser.parse("sequenceDiagram\nA->>B: hi") {} else {
            Issue.record("sequenceDiagram did not route to the sequence parser")
        }
        // The subset's boundary, and it is loud on purpose: the *word the file wrote* comes back,
        // so the page can name it rather than saying "unsupported diagram".
        #expect(
            MermaidParser.parse("stateDiagram-v2\n[*] --> Still") == .unsupported("stateDiagram-v2")
        )
        #expect(MermaidParser.parse("gantt\ntitle A") == .unsupported("gantt"))
        #expect(
            MermaidParser.parse("classDiagram\nAnimal <|-- Duck") == .unsupported("classDiagram")
        )
        #expect(MermaidParser.parse("erDiagram\nA ||--o{ B : has") == .unsupported("erDiagram"))
    }

    @Test("a supported type with nothing readable in it falls back too")
    func emptyDiagramFallsBack() {
        // A blank rectangle is a worse answer than the source and a note, so "flowchart" with no
        // node in it is treated as unsupported rather than drawn empty.
        #expect(MermaidParser.parse("graph TD") == .unsupported("graph"))
        #expect(
            MermaidParser.parse("sequenceDiagram\n%% nothing here") == .unsupported(
                "sequenceDiagram"
            )
        )
        #expect(MermaidParser.parse("") == .unsupported(""))
    }

    @Test("every direction, and TB is a spelling of TD")
    func directions() {
        #expect(flowchart("graph TD\nA-->B")?.direction == .topDown)
        #expect(flowchart("graph TB\nA-->B")?.direction == .topDown)
        #expect(flowchart("graph LR\nA-->B")?.direction == .leftRight)
        #expect(flowchart("graph RL\nA-->B")?.direction == .rightLeft)
        #expect(flowchart("graph BT\nA-->B")?.direction == .bottomUp)
        // An unreadable direction is not a reason to lose the diagram.
        #expect(flowchart("graph\nA-->B")?.direction == .topDown)
        #expect(flowchart("graph sideways\nA-->B")?.direction == .topDown)
    }

    // MARK: - Statements, comments and separators

    @Test("comments go, quoted percent signs stay")
    func comments() {
        let chart = flowchart("""
        graph TD
        %% this whole line is a comment
        A[Start] --> B  %% and this tail
        B --> C["100%% done"]
        """)
        #expect(chart?.nodes.count == 3)
        #expect(chart?.nodes.last?.label == "100%% done")
    }

    @Test("a semicolon separates statements, and one inside a label does not")
    func semicolons() {
        let chart = flowchart("graph TD\nA-->B; B-->C")
        #expect(chart?.edges.count == 2)
        let quoted = flowchart("graph TD\nA[\"one; two\"] --> B")
        #expect(quoted?.nodes.first?.label == "one; two")
        #expect(quoted?.edges.count == 1)
    }

    // MARK: - Node shapes

    @Test("each bracket form, with the two-character ones tested before their halves")
    func shapes() {
        let chart = flowchart("""
        graph TD
        A[Square] --> B(Rounded)
        B --> C((Circle))
        C --> D{Diamond}
        D --> E[[Subroutine]]
        """)
        let shapes = chart?.nodes.map(\.shape)
        #expect(shapes == [.rectangle, .rounded, .circle, .diamond, .subroutine])
        #expect(
            chart?.nodes.map(\.label) == ["Square", "Rounded", "Circle", "Diamond", "Subroutine"]
        )
    }

    @Test("a bare node keeps its id as its label")
    func bareNode() {
        let chart = flowchart("graph TD\nA --> B")
        #expect(chart?.nodes.map(\.id) == ["A", "B"])
        #expect(chart?.nodes.map(\.label) == ["A", "B"])
    }

    @Test("a later bare mention must not blank a label an earlier one set, or the reverse")
    func labelSurvivesLaterMention() {
        // The direction the bug goes depends on which line came second, which is why both are here.
        #expect(flowchart("graph TD\nA[Start] --> B\nB --> A")?.nodes.first?.label == "Start")
        #expect(flowchart("graph TD\nA --> B\nA[Start] --> C")?.nodes.first?.label == "Start")
    }

    @Test("quotes are syntax and are not drawn")
    func quotedLabel() {
        #expect(flowchart("graph TD\nA[\"a [b] c\"] --> B")?.nodes.first?.label == "a [b] c")
    }

    // MARK: - Edges

    @Test("the arrow's length changes its meaning")
    func edgeLengthRule() {
        // Two dashes is a link only with a head; three is one without. Getting this backwards makes
        // `A -- text --> B` parse as an edge with no label and a node called `text`.
        #expect(flowchart("graph TD\nA-->B")?.edges.first?.head == .arrow)
        #expect(flowchart("graph TD\nA---B")?.edges.first?.head == MermaidFlowchart.Tip.none)
        #expect(flowchart("graph TD\nA---B")?.edges.first?.stroke == .solid)
        // `A -- B` is not an edge at all: no head, and only two dashes.
        #expect(flowchart("graph TD\nA -- B")?.edges.isEmpty == true)
    }

    @Test("stroke and tips")
    func edgeStyles() {
        #expect(flowchart("graph TD\nA-.->B")?.edges.first?.stroke == .dotted)
        #expect(flowchart("graph TD\nA-.-B")?.edges.first?.stroke == .dotted)
        #expect(flowchart("graph TD\nA==>B")?.edges.first?.stroke == .thick)
        #expect(flowchart("graph TD\nA===B")?.edges.first?.stroke == .thick)
        #expect(flowchart("graph TD\nA--xB")?.edges.first?.head == .cross)
        #expect(flowchart("graph TD\nA---oB")?.edges.first?.head == .circle)
        let both = flowchart("graph TD\nA<-->B")?.edges.first
        #expect(both?.tail == .arrow)
        #expect(both?.head == .arrow)
    }

    @Test("both label spellings produce the same edge")
    func edgeLabels() {
        // One concept, two syntaxes — nothing downstream should be able to tell which was written.
        let piped = flowchart("graph TD\nA -->|yes| B")?.edges.first
        let inline = flowchart("graph TD\nA -- yes --> B")?.edges.first
        #expect(piped?.label == "yes")
        #expect(inline?.label == "yes")
        #expect(piped == inline)
        #expect(flowchart("graph TD\nA -. maybe .-> B")?.edges.first?.label == "maybe")
        #expect(flowchart("graph TD\nA == sure ==> B")?.edges.first?.label == "sure")
        // The label form must not leave its text behind as a node.
        #expect(flowchart("graph TD\nA -- yes --> B")?.nodes.map(\.id) == ["A", "B"])
    }

    @Test("a chain is read left to right")
    func chains() {
        let chart = flowchart("graph TD\nA --> B --> C")
        #expect(chart?.nodes.map(\.id) == ["A", "B", "C"])
        #expect(chart?.edges.map(\.from) == ["A", "B"])
        #expect(chart?.edges.map(\.to) == ["B", "C"])
    }

    @Test("an ampersand fans out rather than naming a node")
    func ampersandFanOut() {
        let chart = flowchart("graph TD\nA & B --> C")
        #expect(chart?.nodes.map(\.id) == ["A", "B", "C"])
        #expect(chart?.edges.count == 2)
        // Inside a label it is text, not a separator.
        #expect(flowchart("graph TD\nA[Cut & paste] --> B")?.nodes.first?.label == "Cut & paste")
    }

    @Test("an arrow inside a label is not the edge operator")
    func arrowInsideBrackets() {
        // The failure this prevents is not a parse error: it is a node genuinely named `A[a`.
        let chart = flowchart("graph TD\nA[a --> b] --> C")
        #expect(chart?.nodes.map(\.id) == ["A", "C"])
        #expect(chart?.nodes.first?.label == "a --> b")
        #expect(chart?.edges.count == 1)
    }

    @Test("a node id ending in x or o keeps its last letter")
    func idsEndingInTipCharacters() {
        // `x` and `o` are arrow tips, so an id ending in one is where a naive scan eats a character.
        let chart = flowchart("graph TD\nbox --> radio")
        #expect(chart?.nodes.map(\.id) == ["box", "radio"])
    }

    // MARK: - Constructs the subset does not draw

    @Test("a subgraph draws its contents and reports the frame it did not draw")
    func subgraphIsReported() {
        let chart = flowchart("""
        graph TD
        subgraph one [Group]
        A --> B
        end
        B --> C
        style A fill:#f9f
        """)
        // The edges survive — dropping them would lose the diagram to keep a box.
        #expect(chart?.edges.count == 2)
        #expect(chart?.nodes.map(\.id) == ["A", "B", "C"])
        #expect(chart?.undrawn == ["style", "subgraph"])
    }
}
