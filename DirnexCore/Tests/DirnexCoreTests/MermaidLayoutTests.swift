import Foundation
import Testing

@testable import DirnexCore

/// Placing and drawing a diagram (PLAN.md §M18 ▸ Slice 4).
///
/// Every number here is exact, and that is what the injected metric bought: `MarkdownTextMetric
/// .fixedAdvance` is 7 pt a character over a 14 pt line, so a node's width is arithmetic rather
/// than whatever the machine running the tests has installed. A layout asserted against a range
/// would pass through most of the bugs worth catching.
@Suite("Mermaid layout")
struct MermaidLayoutTests {
    private let metric = MarkdownTextMetric.fixedAdvance

    private func flowchart(_ source: String) -> MermaidFlowchartDrawing {
        guard case let .flowchart(chart) = MermaidParser.parse(source) else {
            Issue.record("not a flowchart")
            return MermaidFlowchartDrawing(width: 0, height: 0, nodes: [], edges: [])
        }
        return MermaidFlowchartLayout.lay(out: chart, metric: metric)
    }

    private func sequence(_ source: String) -> MermaidSequenceDrawing {
        guard case let .sequence(diagram) = MermaidParser.parse(source) else {
            Issue.record("not a sequence diagram")
            return MermaidSequenceLayout.lay(
                out: MermaidSequence(participants: [], events: [], undrawn: []),
                metric: metric
            )
        }
        return MermaidSequenceLayout.lay(out: diagram, metric: metric)
    }

    // MARK: - Layering

    @Test("a chain puts one node per layer, stacked down the page")
    func chainLayers() {
        let drawing = flowchart("graph TD\nA --> B --> C")
        let tops = drawing.nodes.map(\.frame.y)
        #expect(tops[0] < tops[1])
        #expect(tops[1] < tops[2])
        // Longest-path layering: each layer is one node's height plus the gap below it.
        #expect(tops[1] - tops[0] == tops[2] - tops[1])
        // A vertical chart puts every node on the same centre line.
        let centres = Set(drawing.nodes.map(\.frame.midX))
        #expect(centres.count == 1)
    }

    @Test("longest path, not shortest: a node waits for its deepest predecessor")
    func longestPath() {
        // C has edges from both A (layer 0) and B (layer 1), so it belongs in layer 2 — a
        // shortest-path layering would put it in 1 and draw an edge that goes nowhere.
        let drawing = flowchart("graph TD\nA --> B\nB --> C\nA --> C")
        let rows = drawing.nodes.map(\.frame.y)
        #expect(rows[0] < rows[1])
        #expect(rows[1] < rows[2])
    }

    @Test("a cycle draws instead of hanging, and its back edge is still drawn")
    func cyclesAreBroken() {
        // The reason cycle-breaking is not an optimization: longest-path layering does not
        // terminate on a cycle, so this would hang a preview over a file a cursor passed.
        let drawing = flowchart("graph TD\nA --> B\nB --> C\nC --> A")
        #expect(drawing.nodes.count == 3)
        #expect(drawing.edges.count == 3)
        #expect(drawing.nodes.map(\.frame.y) == drawing.nodes.map(\.frame.y).sorted())
    }

    @Test("a self-loop neither hangs nor draws a line from a node to itself")
    func selfLoop() {
        let drawing = flowchart("graph TD\nA --> A\nA --> B")
        #expect(drawing.nodes.count == 2)
        // A zero-length edge has no direction, so there is nothing to clip and no arrow to aim.
        #expect(drawing.edges.count == 1)
    }

    @Test("the four directions are two axes and a flip")
    func directions() {
        let down = flowchart("graph TD\nA --> B")
        let up = flowchart("graph BT\nA --> B")
        let right = flowchart("graph LR\nA --> B")
        let left = flowchart("graph RL\nA --> B")
        #expect(down.nodes[0].frame.y < down.nodes[1].frame.y)
        #expect(up.nodes[0].frame.y > up.nodes[1].frame.y)
        #expect(right.nodes[0].frame.x < right.nodes[1].frame.x)
        #expect(left.nodes[0].frame.x > left.nodes[1].frame.x)
        // A flip is a mirror, so the canvas is the same size either way.
        #expect(down.width == up.width)
        #expect(down.height == up.height)
        #expect(right.width == left.width)
    }

    @Test("a flip keeps every node on the canvas")
    func flipStaysInBounds() {
        let up = flowchart("graph BT\nA[A long label here] --> B\nB --> C")
        for node in up.nodes {
            #expect(node.frame.y >= 0)
            #expect(node.frame.maxY <= up.height)
        }
    }

    // MARK: - Sizing

    @Test("a node is as wide as its label")
    func nodeWidth() {
        let drawing = flowchart("graph TD\nA[abcd] --> B[abcdefgh]")
        // 7 pt a character plus 12 pt of padding on each side.
        #expect(drawing.nodes[0].frame.width == 4 * 7 + 24)
        #expect(drawing.nodes[1].frame.width == 8 * 7 + 24)
        #expect(drawing.nodes[0].frame.height == 14 + 16)
    }

    @Test("a short label still gets a box worth looking at")
    func minimumWidth() {
        #expect(flowchart("graph TD\nA --> B").nodes[0].frame.width == 36)
    }

    @Test("the two tapering shapes are sized by geometry, not by taste")
    func taperedShapes() {
        let drawing = flowchart("graph TD\nA{abcd} --> B((abcd))")
        // A rhombus of width W and height H holds a centred w x h box exactly when w/W + h/H <= 1,
        // so doubling both is the smallest diamond that fits its text.
        let diamond = drawing.nodes[0].frame
        #expect(diamond.width == 2 * (4 * 7 + 12))
        #expect(diamond.height == 2 * (14 + 8))
        #expect(4 * 7 / diamond.width + 14 / diamond.height <= 1)
        // A circle stays a circle.
        let circle = drawing.nodes[1].frame
        #expect(circle.width == circle.height)
    }

    // MARK: - Edges

    @Test("an edge is clipped to both outlines, so it starts and ends on a border")
    func edgesAreClipped() {
        let drawing = flowchart("graph TD\nA --> B")
        let edge = drawing.edges[0]
        #expect(edge.start.y == drawing.nodes[0].frame.maxY)
        #expect(edge.end.y == drawing.nodes[1].frame.y)
        // Neither endpoint is inside the box it leaves.
        #expect(edge.start.y < edge.end.y)
    }

    @Test("a diamond's edge leaves its point, not its bounding box")
    func diamondClipping() {
        let drawing = flowchart("graph TD\nA{yes} --> B")
        let diamond = drawing.nodes[0].frame
        // Straight down from the centre, the rhombus boundary is its bottom vertex.
        #expect(drawing.edges[0].start.y == diamond.maxY)
        #expect(drawing.edges[0].start.x == diamond.midX)
    }

    @Test("an edge spanning layers bends around them instead of crossing them")
    func longEdgesAreRouted() {
        // The bug this pins was visible and only visible in a picture: `A --> D` drawn as one
        // straight line ran through B, through C, and through both of their labels. Dummy nodes in
        // the layers between are what steer it past them.
        let drawing = flowchart("graph TD\nA --> B --> C --> D\nA --> D")
        let long = drawing.edges.first { $0.label == nil && $0.points.count > 2 }
        #expect(long != nil)
        // One bend per layer it crosses: two ends plus B's layer and C's.
        #expect(long?.points.count == 4)
        // And the bend is genuinely to the side of the boxes it passes, not through them.
        let column = drawing.nodes[1].frame
        for point in long?.points.dropFirst().dropLast() ?? [] {
            #expect(point.x < column.x || point.x > column.maxX)
        }
    }

    @Test("a routed edge stays on the canvas")
    func routedEdgesAreInBounds() {
        // Sizing the canvas from the *boxes* is the natural thing and is wrong: a bend sits outside
        // every one of them, so a back edge left the picture on the right and came back in.
        let drawing = flowchart("graph TD\nA --> B --> C --> D\nD ==> A")
        for edge in drawing.edges {
            for point in edge.points {
                #expect(point.x >= 0 && point.x <= drawing.width)
                #expect(point.y >= 0 && point.y <= drawing.height)
            }
        }
    }

    @Test("an adjacent-layer edge stays a straight line")
    func shortEdgesAreNotBent() {
        // The corollary, and worth pinning separately: a dummy where none is needed would put a
        // pointless kink in every ordinary arrow.
        #expect(flowchart("graph TD\nA --> B").edges[0].points.count == 2)
    }

    @Test("the canvas holds an edge label wider than the nodes it sits between")
    func canvasHoldsWideLabel() {
        // A label centred between two small nodes overhangs both, and a canvas sized from the
        // nodes alone would clip it — which reads as a bug in the diagram, not in its box.
        let drawing = flowchart("graph TD\nA -->|a very long edge label indeed| B")
        let label = drawing.edges[0]
        #expect(label.labelCentre.x + metric.width(label.label ?? "") / 2 <= drawing.width)
    }

    // MARK: - Sequence diagrams

    @Test("participants take columns in order, with lifelines under them")
    func sequenceColumns() {
        let drawing = sequence("""
        sequenceDiagram
        participant A as Alice
        participant B as Bob
        A->>B: hi
        """)
        #expect(drawing.participants.map(\.label) == ["Alice", "Bob"])
        #expect(drawing.participants[0].frame.midX < drawing.participants[1].frame.midX)
        #expect(drawing.lifelineBottom > drawing.participants[0].frame.maxY)
        // The message runs between the two lifelines, at one y.
        let message = drawing.messages[0]
        #expect(message.points.count == 2)
        #expect(message.points[0].y == message.points[1].y)
        #expect(message.points[0].x == drawing.participants[0].frame.midX)
        #expect(message.points[1].x == drawing.participants[1].frame.midX)
    }

    @Test("a long message label pushes its columns apart, spread over the gaps it spans")
    func labelWidensColumns() {
        let narrow = sequence("sequenceDiagram\nA->>B: hi")
        let wide = sequence("sequenceDiagram\nA->>B: a considerably longer message than that one")
        #expect(wide.width > narrow.width)

        // Spanning three columns, the demand is shared rather than paid at one gap — so neither
        // gap grows to the whole label's width.
        let spanning = sequence("sequenceDiagram\nparticipant A\nparticipant B\nparticipant C\n"
            + "A->>C: a considerably longer message than that one")
        let gaps = zip(
            spanning.participants.dropFirst().map(\.frame.midX),
            spanning.participants.map(\.frame.midX)
        ).map { $0 - $1 }
        #expect(gaps.count == 2)
        #expect(gaps[0] == gaps[1])
        #expect(gaps[0] < metric.width("a considerably longer message than that one"))
    }

    @Test("events take rows in the order they were written")
    func sequenceRows() {
        let drawing = sequence("""
        sequenceDiagram
        A->>B: one
        B-->>A: two
        Note over A,B: a note
        A->>B: three
        """)
        #expect(drawing.messages.count == 3)
        let ys = drawing.messages.map { $0.points[0].y }
        #expect(ys == ys.sorted())
        // The note sits between the second and third messages, where it was written.
        let note = drawing.notes[0]
        #expect(note.frame.y > ys[1])
        #expect(note.frame.maxY < ys[2])
    }

    @Test("a self-message loops out and back rather than drawing nothing")
    func selfMessage() {
        let drawing = sequence("sequenceDiagram\nA->>A: think")
        let message = drawing.messages[0]
        #expect(message.isSelf)
        #expect(message.points.count == 4)
        #expect(message.points[0].x == message.points[3].x)
        #expect(message.points[1].x > message.points[0].x)
        // The loop and its label push the canvas out past the last lifeline.
        #expect(drawing.width > message.points[1].x)
    }

    @Test("an activation runs from its activate to its deactivate")
    func activations() {
        let drawing = sequence("""
        sequenceDiagram
        A->>B: go
        activate B
        B-->>A: done
        deactivate B
        A->>B: again
        """)
        #expect(drawing.activations.count == 1)
        let bar = drawing.activations[0]
        #expect(bar.y < drawing.messages[1].points[0].y)
        #expect(bar.maxY > drawing.messages[1].points[0].y)
        #expect(bar.maxY < drawing.messages[2].points[0].y)
    }

    @Test("an activation the file never closed runs to the foot rather than vanishing")
    func unclosedActivation() {
        // A real document forgets a `deactivate`, and dropping the bar shows a participant as idle
        // for the rest of a diagram that says otherwise.
        let drawing = sequence("sequenceDiagram\nA->>B: go\nactivate B\nB-->>A: done")
        #expect(drawing.activations.count == 1)
        #expect(drawing.activations[0].maxY == drawing.lifelineBottom)
    }
}
