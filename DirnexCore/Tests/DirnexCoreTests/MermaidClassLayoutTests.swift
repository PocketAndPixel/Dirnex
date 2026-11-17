import Foundation
import Testing

@testable import DirnexCore

/// Placing class and ER diagrams (PLAN.md §M39 ▸ Slice 14).
///
/// The fixed-advance metric is 7 points a character over a 14-point line, so a box's size is
/// arithmetic. The rest are properties the picture must keep: the first-written class above, a
/// namespace around its members, and a line between groups passing between the boxes in them.
@Suite("Mermaid class and ER layout")
struct MermaidClassLayoutTests {
    private let metric = MarkdownTextMetric.fixedAdvance

    private func classes(_ body: String) -> (MermaidClassDiagram, MermaidClassDrawing) {
        guard case let .classDiagram(diagram) = MermaidParser.parse("classDiagram\n" + body) else {
            Issue.record("not a class diagram")
            let empty = MermaidClassDiagram(
                direction: .topDown,
                nodes: [],
                namespaces: [],
                relations: [],
                undrawn: []
            )
            return (empty, MermaidClassLayout.lay(out: empty, metric: metric))
        }
        return (diagram, MermaidClassLayout.lay(out: diagram, metric: metric))
    }

    private func entities(_ body: String) -> (MermaidERDiagram, MermaidERDrawing) {
        guard case let .entityRelationship(diagram) = MermaidParser.parse("erDiagram\n" + body) else {
            Issue.record("not an ER diagram")
            let empty = MermaidERDiagram(
                direction: .topDown,
                entities: [],
                groups: [],
                relationships: [],
                undrawn: []
            )
            return (empty, MermaidERLayout.lay(out: empty, metric: metric))
        }
        return (diagram, MermaidERLayout.lay(out: diagram, metric: metric))
    }

    private func frame(_ id: String, in laid: (MermaidClassDiagram, MermaidClassDrawing)) -> MermaidRect {
        laid.1.boxes[laid.0.nodes.firstIndex { $0.id == id } ?? 0].frame
    }

    // MARK: - Classes

    @Test("the class written first is drawn above, or before across the page")
    func firstWrittenFirst() {
        let down = classes("A <|-- B\nC --|> D")
        #expect(frame("A", in: down).maxY < frame("B", in: down).y)
        #expect(frame("C", in: down).maxY < frame("D", in: down).y)
        let across = classes("direction LR\nA <|-- B")
        #expect(frame("A", in: across).maxX < frame("B", in: across).x)
    }

    @Test("a class is three bands, and an empty one is still drawn")
    func compartments() {
        let laid = classes(
            "class Empty\nclass Full {\n  <<interface>>\n  +int x\n  +run()\n  +stop()\n}"
        )
        let empty = laid.1.boxes[0]
        // One line for the name and three bands' padding, 6 above and below each.
        #expect(empty.frame.height == 14 + 36)
        #expect(empty.frame.width == 60)
        #expect(empty.rules == [empty.frame.y + 26, empty.frame.y + 38])
        let full = laid.1.boxes[1]
        #expect(full.frame.height == 14 * 5 + 36)
        // The annotation, then the name, centered; then the members from the left.
        #expect(full.texts.map(\.string) == ["«interface»", "Full", "+int x", "+run()", "+stop()"])
        #expect(full.texts.map(\.isLeading) == [false, false, true, true, true])
        #expect(full.texts[2].point.x == full.frame.x + 10)
        #expect(full.rules[0] < full.texts[2].point.y && full.texts[2].point.y < full.rules[1])
        #expect(full.texts[3].point.y > full.rules[1])
    }

    @Test("the name is measured in the bold face it is drawn in")
    func boldName() {
        let wide = MarkdownTextMetric(
            lineHeight: 14,
            boldWidth: { Double($0.count) * 20 },
            width: { Double($0.count) * 7 }
        )
        guard case let .classDiagram(diagram) = MermaidParser.parse("classDiagram\nclass Wide") else {
            Issue.record("not a class diagram")
            return
        }
        #expect(
            MermaidClassLayout.lay(out: diagram, metric: wide).boxes[0].frame.width == 4 * 20 + 20
        )
        #expect(MermaidClassLayout.lay(out: diagram, metric: metric).boxes[0].frame.width == 60)
    }

    @Test("a cardinality sits outside both boxes and clear of the line")
    func cardinalitiesClear() {
        let laid = classes(
            "Customer \"1\" --> \"*\" Ticket : buys\nStudent \"0..1\" --o \"1..*\" Course"
        )
        for edge in laid.1.edges {
            #expect(edge.cardinalities.count == 2)
            for text in edge.cardinalities {
                let box = textBox(text.string, at: text.point)
                for drawn in laid.1.boxes {
                    #expect(!box.intersects(drawn.frame), "“\(text.string)” overlaps a box")
                }
                #expect(!edge.points.indices.dropLast().contains { index in
                    box.cuts(from: edge.points[index], to: edge.points[index + 1])
                }, "“\(text.string)” sits on its line")
            }
        }
    }

    @Test("a namespace holds its members, and a nested one sits inside its parent")
    func namespacesContain() {
        let laid = classes("""
        namespace Outer {
            class A
            namespace Inner {
                class B
            }
        }
        class C
        A --> B
        B --> C
        """)
        let outer = laid.1.groups[0].frame
        let inner = laid.1.groups[1].frame
        #expect(outer.contains(frame("A", in: laid)))
        #expect(inner.contains(frame("B", in: laid)))
        #expect(outer.contains(inner))
        #expect(!outer.intersects(frame("C", in: laid)))
        #expect(laid.1.groups.map(\.title.string) == ["Outer", "Inner"])
    }

    @Test("a line leaving a namespace passes between the boxes in it rather than through them")
    func crossingLinesAvoidBoxes() {
        // A line from `top` to `out` leaves `N`, below whose `top` sit `middle` and `bottom`: drawn
        // straight from `top` toward the outside, it ran through both (Slice 14's first look, on
        // the corpus's NuGet README).
        let laid = classes("""
        namespace N {
            class top
            class middle
            class bottom
        }
        top --> middle
        middle --> bottom
        top --> out
        """)
        let edge = laid.1.edges[2]
        for id in ["middle", "bottom"] {
            let box = frame(id, in: laid)
            #expect(!edge.points.indices.dropLast().contains { index in
                box.cuts(from: edge.points[index], to: edge.points[index + 1])
            }, "the line crosses “\(id)”")
        }
        #expect(onOutline(edge.start, of: frame("top", in: laid)))
        #expect(onOutline(edge.end, of: frame("out", in: laid)))
    }

    @Test("a note goes above its class, and a lollipop's interface beside its line's circle")
    func notesAndLollipops() {
        let laid = classes("note for Duck \"swims\"\nDuck --() Flyer")
        let note = laid.1.boxes[1]
        #expect(note.kind == .note)
        #expect(note.frame.maxY < frame("Duck", in: laid).y)
        #expect(laid.1.edges[0].isNoteLink)
        let interface = laid.1.boxes[2]
        #expect(interface.kind == .interface)
        #expect(interface.texts.map(\.string) == ["Flyer"])
        #expect(laid.1.edges[1].toEnd == .lollipop)
    }

    @Test("everything is on the canvas and no two boxes overlap")
    func onCanvas() {
        let laid = classes("""
        namespace Shapes {
            class Shape { <<interface>> +area() double }
            class Circle
        }
        Shape <|.. Circle
        Circle "1" *-- "many" Point : center
        Point --> Point : next
        Circle --() Drawable
        note for Point "x, y"
        """)
        let drawing = laid.1
        let frames = drawing.boxes.map(\.frame)
        for (index, frame) in frames.enumerated() {
            #expect(frame.x >= 0 && frame.maxX <= drawing.width)
            #expect(frame.y >= 0 && frame.maxY <= drawing.height)
            for other in frames[(index + 1)...] { #expect(!frame.intersects(other)) }
        }
        for edge in drawing.edges {
            for point in edge.points + edge.cardinalities.map(\.point) {
                #expect(point.x >= 0 && point.x <= drawing.width)
                #expect(point.y >= 0 && point.y <= drawing.height)
            }
        }
        #expect(classes("A --> B").1 == classes("A --> B").1)
    }

    // MARK: - ER

    @Test("an entity is a table whose keys and comment columns appear only when used")
    func tables() {
        let laid = entities("""
        TWO {
            string name
        }
        THREE {
            string id PK
            string name
        }
        FOUR {
            int n "a comment"
        }
        BARE
        """)
        #expect(laid.1.entities.map(\.columns.count) == [1, 2, 3, 0])
        let two = laid.1.entities[0]
        // A 14-point band padded 8 above and below, then one 22-point row.
        #expect(two.frame.height == 30 + 22)
        #expect(two.rules == [two.frame.y + 30])
        #expect(two.texts.map(\.string) == ["TWO", "string", "name"])
        #expect(two.texts[1].point.x == two.frame.x + 8)
        // An entity with no attributes is its name in a roomier box.
        let bare = laid.1.entities[3]
        #expect(bare.frame.height == 14 + 28)
        #expect(bare.frame.width == 80)
        #expect(bare.rules.isEmpty)
    }

    @Test("a wide name widens the last column, so the table still fills its box")
    func lastColumnTakesTheSlack() {
        let laid = entities("A_VERY_LONG_ENTITY_NAME {\n  int x\n}")
        let entity = laid.1.entities[0]
        #expect(entity.frame.width == Double("A_VERY_LONG_ENTITY_NAME".count) * 7 + 24)
        // The type column is its own width; the name column took the rest.
        #expect(entity.columns == [entity.frame.x + 3 * 7 + 16])
    }

    @Test("a subgraph holds its entities, and a relationship to it ends on its outline")
    func subgraphs() {
        let laid = entities("""
        subgraph Sales
            CUSTOMER ||--o{ ORDER : places
        end
        Sales ||--|| LEDGER : posts
        """)
        let group = laid.1.groups[0].frame
        #expect(group.contains(laid.1.entities[0].frame))
        #expect(group.contains(laid.1.entities[1].frame))
        #expect(!group.intersects(laid.1.entities[2].frame))
        #expect(onOutline(laid.1.edges[1].start, of: group))
        #expect(laid.1.edges.map(\.isIdentifying) == [true, true])
    }

    @Test("the first entity is above, and each relationship keeps its own cardinalities")
    func erOrder() {
        let laid = entities("CUSTOMER ||--o{ ORDER : places\nORDER }|..|{ PROMO : uses")
        let frames = laid.1.entities.map(\.frame)
        #expect(frames[0].maxY < frames[1].y)
        #expect(frames[1].maxY < frames[2].y)
        #expect(laid.1.edges.map(\.fromCardinality) == [.exactlyOne, .oneOrMore])
        #expect(laid.1.edges.map(\.toCardinality) == [.zeroOrMore, .oneOrMore])
        #expect(laid.1.edges.map(\.isIdentifying) == [true, false])
    }

    // MARK: - Helpers

    private func textBox(_ text: String, at center: MermaidPoint) -> MermaidRect {
        let width = metric.width(text)
        return MermaidRect(x: center.x - width / 2, y: center.y - 7, width: width, height: 14)
    }

    private func onOutline(_ point: MermaidPoint, of frame: MermaidRect) -> Bool {
        let near = 0.01
        let inside = point.x >= frame.x - near && point.x <= frame.maxX + near
            && point.y >= frame.y - near && point.y <= frame.maxY + near
        let onEdge = abs(point.x - frame.x) < near || abs(point.x - frame.maxX) < near
            || abs(point.y - frame.y) < near || abs(point.y - frame.maxY) < near
        return inside && onEdge
    }
}

extension MermaidRect {
    func contains(_ other: MermaidRect) -> Bool {
        other.x >= x && other.maxX <= maxX && other.y >= y && other.maxY <= maxY
    }

    /// Whether the segment passes through the inside of the rectangle (Liang–Barsky clipping),
    /// written here rather than borrowed from the code under test.
    func cuts(from start: MermaidPoint, to end: MermaidPoint) -> Bool {
        let dx = end.x - start.x
        let dy = end.y - start.y
        var low = 0.0
        var high = 1.0
        let shrink = 0.5
        for (direction, distance) in [
            (-dx, start.x - (x + shrink)), (dx, (maxX - shrink) - start.x),
            (-dy, start.y - (y + shrink)), (dy, (maxY - shrink) - start.y)
        ] {
            if direction == 0 {
                if distance < 0 { return false }
            } else {
                let ratio = distance / direction
                if direction < 0 { low = max(low, ratio) } else { high = min(high, ratio) }
                if low > high { return false }
            }
        }
        return true
    }
}
