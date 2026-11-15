import Foundation
import Testing

@testable import DirnexCore

/// Placing a state diagram (PLAN.md §M39 ▸ Slice 13).
///
/// The fixed-advance metric makes every size arithmetic (`MermaidLayoutTests`), so most claims
/// below are properties the picture has to keep — nothing overlaps, everything is on the canvas,
/// the inside of a composite is inside it — checked over real diagrams, the undici lifecycle among
/// them, since that is the one state diagram the M39 corpus found on this Mac.
@Suite("Mermaid state diagram layout")
struct MermaidStateLayoutTests {
    private let metric = MarkdownTextMetric.fixedAdvance

    private func lay(_ source: String) -> (MermaidStateDiagram, MermaidStateDrawing) {
        guard case let .state(diagram) = MermaidParser.parse(source) else {
            Issue.record("not a state diagram")
            let empty = MermaidStateDiagram(
                direction: .topDown,
                states: [],
                regions: [],
                transitions: [],
                undrawn: []
            )
            return (empty, MermaidStateLayout.lay(out: empty, metric: metric))
        }
        return (diagram, MermaidStateLayout.lay(out: diagram, metric: metric))
    }

    private func frame(_ id: String, in laid: (MermaidStateDiagram, MermaidStateDrawing)) -> MermaidRect {
        let index = laid.0.states.firstIndex { $0.id == id } ?? 0
        return laid.1.nodes[index].frame
    }

    static let undici = """
    stateDiagram-v2
      [*] --> idle
      idle --> pending : connect
      idle --> destroyed : destroy/close
      pending --> idle : timeout
      pending --> destroyed : destroy
      state close_fork <<fork>>
      pending --> close_fork : close
      close_fork --> processing
      close_fork --> destroyed
      pending --> processing : process
      processing --> pending : keepalive
      processing --> destroyed : done
      processing --> destroyed : destroy
      destroyed --> [*]
      state processing {
          [*] --> running
          running --> closing : close
          running --> busy : needDrain
          busy --> running : drainComplete
          running --> [*] : keepalive
          closing --> [*] : done
      }
    """

    static let concurrency = """
    stateDiagram-v2
        [*] --> Active
        state Active {
            [*] --> NumLockOff
            NumLockOff --> NumLockOn : EvNumLockPressed
            NumLockOn --> NumLockOff : EvNumLockPressed
            --
            [*] --> CapsLockOff
            CapsLockOff --> CapsLockOn : EvCapsLockPressed
            CapsLockOn --> CapsLockOff : EvCapsLockPressed
        }
    """

    // MARK: - Labels

    @Test("two labeled transitions between one pair of states sit side by side")
    func twoWayLabels() {
        // On the flowchart's layout these were one line with both labels on top of each other.
        let laid = lay("stateDiagram-v2\nA --> B : forward\nB --> A : back")
        let edges = laid.1.edges
        #expect(edges.count == 2)
        let boxes = edges.map { labelBox($0) }
        #expect(!boxes[0].intersects(boxes[1]))
        // And they are two lines, not one: each bends through its own label.
        #expect(edges[0].points.count == 3)
        #expect(edges[0].points[1] == edges[0].labelCenter)
        #expect(edges[0].labelCenter != edges[1].labelCenter)
    }

    @Test("no two labels and no two boxes overlap, over real diagrams")
    func nothingOverlaps() {
        for source in [Self.undici, Self.concurrency] {
            let (diagram, drawing) = lay(source)
            let boxes = drawing.edges.filter { $0.label != nil }.map { labelBox($0) }
            for first in boxes.indices {
                for second in boxes.indices where second > first {
                    #expect(!boxes[first].intersects(boxes[second]))
                }
            }
            // Boxes in one region never overlap; a composite holds its inside, so only siblings are
            // compared.
            let siblings = Dictionary(grouping: diagram.states.indices) { parent(of: $0, in: diagram) }
            for group in siblings.values {
                for first in group {
                    for second in group where second > first {
                        #expect(!drawing.nodes[first].frame.intersects(drawing.nodes[second].frame))
                    }
                }
            }
        }
    }

    // MARK: - Composites

    @Test("a composite holds its inside below its title, and its transitions end on its border")
    func compositeHoldsItsInside() {
        let laid = lay(Self.undici)
        let processing = frame("processing", in: laid)
        let index = laid.0.states.firstIndex { $0.id == "processing" } ?? 0
        let rule = laid.1.nodes[index].ruleY ?? 0
        #expect(rule > processing.y)
        for id in ["running", "closing", "busy"] {
            let inner = frame(id, in: laid)
            #expect(inner.x > processing.x && inner.maxX < processing.maxX)
            #expect(inner.y > rule && inner.maxY < processing.maxY)
        }
        // `process` ends on the composite's outline.
        let process = laid.1.edges.first { $0.label == "process" }
        #expect(process.map { onOutline($0.end, of: processing) } == true)
    }

    @Test("a transition into another composite's state crosses the border to reach it")
    func crossBorder() {
        let laid = lay("""
        stateDiagram-v2
          [*] --> Outer
          state Outer {
            [*] --> inner1
            inner1 --> [*]
          }
          Outer --> x
          x --> inner1 : cross
        """)
        let cross = laid.1.edges.first { $0.label == "cross" }
        let inner = frame("inner1", in: laid)
        let outer = frame("Outer", in: laid)
        #expect(cross.map { onOutline($0.end, of: inner) } == true)
        #expect(cross.map { onOutline($0.start, of: frame("x", in: laid)) } == true)
        // The line ends inside the composite, which is the whole point of drawing it this way.
        #expect(cross.map { outer.contains($0.end) } == true)
    }

    @Test("regions sit side by side with a dashed line between each two")
    func regions() {
        let laid = lay(Self.concurrency)
        #expect(laid.1.dividers.count == 1)
        let divider = laid.1.dividers[0]
        #expect(divider[0].x == divider[1].x)
        #expect(frame("NumLockOff", in: laid).maxX < divider[0].x)
        #expect(frame("CapsLockOff", in: laid).x > divider[0].x)
    }

    @Test("an inside runs top to bottom in a left-to-right diagram")
    func nestedDirection() {
        let laid = lay("""
        stateDiagram-v2
          direction LR
          [*] --> P
          state P {
            a --> b
          }
          P --> Q
        """)
        // The diagram runs across the page …
        #expect(frame("P", in: laid).maxX < frame("Q", in: laid).x)
        // … and P's inside down it, Mermaid's default for a nested block.
        #expect(frame("a", in: laid).maxY < frame("b", in: laid).y)
        #expect(frame("a", in: laid).midX == frame("b", in: laid).midX)
    }

    // MARK: - Shapes

    @Test("a fork bar lies across the flow")
    func barsLieAcross() {
        let down = frame("f", in: lay("stateDiagram-v2\nstate f <<fork>>\n[*] --> f\nf --> A"))
        #expect(down.width > down.height)
        let across = frame("f", in: lay("stateDiagram-v2\ndirection LR\nstate f <<fork>>\nf --> A"))
        #expect(across.height > across.width)
    }

    @Test("a box with lines under its title draws a rule between them")
    func titledBox() {
        let laid = lay("stateDiagram-v2\nt : one\nt : two\nt : three")
        let node = laid.1.nodes[0]
        #expect(node.texts.map(\.string) == ["one", "two", "three"])
        let rule = node.ruleY ?? 0
        #expect(node.texts[0].center.y < rule)
        #expect(node.texts[1].center.y > rule)
        #expect(node.frame.height == 3 * 14 + 2 * 8 + 2 * 4)
    }

    // MARK: - Loops and notes

    @Test("a transition to itself loops beside its state, which keeps its column")
    func loops() {
        let laid = lay("stateDiagram-v2\nA --> B\nB --> B : retry")
        let loop = laid.1.edges.first { $0.label == "retry" }
        let box = frame("B", in: laid)
        #expect(loop?.points.count == 4)
        #expect(
            loop.map { abs($0.start.x - box.maxX) < 0.001 && abs($0.end.x - box.maxX) < 0.001 } == true
        )
        #expect(loop.map { $0.labelCenter.x > box.maxX } == true)
        // The loop's room is kept on both sides, so the straight edge above stays straight.
        #expect(frame("A", in: laid).midX == box.midX)
        #expect(laid.1.width >= (loop?.labelCenter.x ?? 0) + metric.width("retry") / 2)
    }

    @Test("a note sits on its side, and its state still lines up with its neighbors")
    func notes() {
        let laid = lay("""
        stateDiagram-v2
            S1 --> S2
            note right of S1 : on the right
            note left of S2 : on the left
        """)
        let notes = laid.1.notes
        #expect(notes.count == 2)
        #expect(notes[0].frame.x > frame("S1", in: laid).maxX)
        #expect(notes[1].frame.maxX < frame("S2", in: laid).x)
        // Lined up by the state's own box, not by its slot with the note in it.
        #expect(abs(frame("S1", in: laid).midX - frame("S2", in: laid).midX) < 0.001)
        // The note's link runs from the note to the state.
        #expect(notes[0].link.count == 2)
    }

    // MARK: - The whole

    @Test("a long transition runs straight past the states it skips")
    func longEdgesStraighten() {
        // With every layer centered on its own, this edge zig-zagged from one side to the other.
        let laid = lay("stateDiagram-v2\nA --> B\nB --> C\nC --> D\nA --> D")
        let long = laid.1.edges.last
        let bends = long?.points.dropFirst().dropLast().map(\.x) ?? []
        // One bend per layer between A and D, half-layers included.
        #expect(bends.count == 5)
        guard bends.count == 5 else { return }
        // Beside B, between B and C, and beside C it is one vertical line; only the bends next to
        // its ends lean in toward A and D.
        #expect(bends[1] == bends[2])
        #expect(bends[2] == bends[3])
        for id in ["B", "C"] {
            let box = frame(id, in: laid)
            #expect(bends[2] > box.maxX || bends[2] < box.x)
        }
    }

    @Test("ordering sweeps up as well as down, and keeps the fewest crossings")
    func orderingSweeps() {
        // a, b and c on top, x and y below; a and c both lead to y, b to x. A downward pass leaves
        // x and y tied in their own order, so a → y crosses b → x, and only reordering the top
        // layer — an upward pass — uncrosses it.
        let edges: [(from: Int, to: Int)?] = [(0, 4), (2, 4), (1, 3)]
        let once = MermaidLayering.rank(count: 5, edges: edges)
        let swept = MermaidLayering.rank(count: 5, edges: edges, sweeps: 8)
        #expect(crossings(once) == 1)
        #expect(crossings(swept) == 0)
    }

    @Test("everything drawn is on the canvas")
    func inBounds() {
        for source in [Self.undici, Self.concurrency] {
            let drawing = lay(source).1
            let points = drawing.edges.flatMap(\.points)
                + drawing.nodes.flatMap { [
                    MermaidPoint(x: $0.frame.x, y: $0.frame.y),
                    MermaidPoint(x: $0.frame.maxX, y: $0.frame.maxY)
                ] }
            for point in points {
                #expect(point.x >= 0 && point.x <= drawing.width)
                #expect(point.y >= 0 && point.y <= drawing.height)
            }
        }
    }

    @Test("the same file draws the same picture every time")
    func deterministic() {
        #expect(lay(Self.undici).1 == lay(Self.undici).1)
    }
}

// MARK: - Helpers

extension MermaidStateLayoutTests {
    /// One segment's place: its upper layer, and its ends' positions in theirs.
    private struct Segment {
        let layer: Int
        let upper: Int
        let lower: Int
    }

    /// Crossings between neighboring layers, counted by hand rather than by the code under test.
    private func crossings(_ ranking: MermaidRanking) -> Int {
        var place: [Int: (layer: Int, index: Int)] = [:]
        for (layer, nodes) in ranking.layers.enumerated() {
            for (index, node) in nodes.enumerated() { place[node] = (layer, index) }
        }
        let segments = ranking.segments.compactMap { segment -> Segment? in
            guard let upper = place[segment.upper], let lower = place[segment.lower] else { return nil }
            return Segment(layer: upper.layer, upper: upper.index, lower: lower.index)
        }
        var count = 0
        for first in segments.indices {
            for second in segments.indices where second > first {
                let one = segments[first]
                let two = segments[second]
                guard one.layer == two.layer else { continue }
                if (one.upper - two.upper) * (one.lower - two.lower) < 0 { count += 1 }
            }
        }
        return count
    }

    private func labelBox(_ edge: MermaidStateDrawing.Edge) -> MermaidRect {
        let width = metric.width(edge.label ?? "")
        return MermaidRect(
            x: edge.labelCenter.x - width / 2,
            y: edge.labelCenter.y - 7,
            width: width,
            height: 14
        )
    }

    private func onOutline(_ point: MermaidPoint, of frame: MermaidRect) -> Bool {
        let near = 0.01
        let inside = point.x >= frame.x - near && point.x <= frame.maxX + near
            && point.y >= frame.y - near && point.y <= frame.maxY + near
        let onEdge = abs(point.x - frame.x) < near || abs(point.x - frame.maxX) < near
            || abs(point.y - frame.y) < near || abs(point.y - frame.maxY) < near
        return inside && onEdge
    }

    /// The composite a state is drawn inside, or `-1` at the top level.
    private func parent(of state: Int, in diagram: MermaidStateDiagram) -> Int {
        diagram.states.firstIndex { $0.regions.contains { $0.states.contains(state) } } ?? -1
    }
}

extension MermaidRect {
    func intersects(_ other: MermaidRect) -> Bool {
        x < other.maxX && other.x < maxX && y < other.maxY && other.y < maxY
    }

    func contains(_ point: MermaidPoint) -> Bool {
        point.x >= x && point.x <= maxX && point.y >= y && point.y <= maxY
    }
}

// MARK: - Routing through a border (§M39 ▸ Slice 14)

extension MermaidStateLayoutTests {
    @Test("a transition leaving a composite passes between the states inside it")
    func crossingRoutesInside() {
        // Before §M39 ▸ Slice 14 the line ran straight from `a` toward the outside, through `b`
        // and `c`; now it reaches the composite's edge through a port the inside is ranked with.
        let laid = lay("""
        stateDiagram-v2
          state Outer {
            [*] --> a
            a --> b
            b --> c
          }
          a --> out : leave
        """)
        let leave = laid.1.edges.first { $0.label == "leave" }
        for id in ["b", "c"] {
            let box = frame(id, in: laid)
            let points = leave?.points ?? []
            #expect(!points.indices.dropLast().contains { index in
                box.cuts(from: points[index], to: points[index + 1])
            }, "the line crosses “\(id)”")
        }
        #expect(leave.map { onOutline($0.start, of: frame("a", in: laid)) } == true)
        #expect(leave.map { onOutline($0.end, of: frame("out", in: laid)) } == true)
    }

    @Test("a transition back into a composite comes in from below, not over its top")
    func backEdgeEntersFromBelow() {
        // `x` is below `Outer`, so the line into `inner1` runs against the flow. With its port in
        // the channel above the inside, it climbed the whole composite to come down onto `inner1`.
        let laid = lay("""
        stateDiagram-v2
          [*] --> Outer
          state Outer {
            [*] --> inner1
            inner1 --> [*]
          }
          Outer --> x
          x --> inner1 : cross
        """)
        let cross = laid.1.edges.first { $0.label == "cross" }
        let inner = frame("inner1", in: laid)
        #expect(cross?.points.allSatisfy { $0.y >= inner.y - 0.01 } == true)
        #expect(cross.map { onOutline($0.end, of: inner) } == true)
    }
}
