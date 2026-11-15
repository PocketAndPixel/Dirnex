import Foundation

/// Boxes, some of them inside titled groups, joined by lines: what a class diagram and an ER diagram
/// both are once their text is measured (PLAN.md §M39 ▸ Slice 14).
///
/// Laid out by the state diagram's region layout, whole. A group is a composite state with one
/// region, a box is a simple state whose size the caller chose, and a line is a transition. That
/// gives a class diagram's namespaces and an ER diagram's subgraphs everything Slice 13 built — each
/// group laid out from the inside and taking part in its parent as one box, a line into a member
/// crossing the border to reach it, a half-layer slot for every label, balanced placement, loops —
/// with no second copy of any of it. Only the layout is shared: what a box holds and how a line ends
/// stay with each dialect's own drawing.
struct MermaidBoxGraph {
    struct Node {
        /// The box's size, or `nil` for a group, which is as big as what it holds.
        let box: MermaidSize?
        /// A group's title. A box's text is its caller's business.
        let title: String
        /// The group this node is drawn inside, by index, or `nil` at the top level.
        let parent: Int?
        /// A group's own direction. `nil` follows the group it is in, and the top level's follows
        /// the diagram's — a state composite's inside runs top to bottom, and a namespace's does not.
        let direction: MermaidFlowchart.Direction?

        var isGroup: Bool { box == nil }
    }

    struct Link {
        let from: Int
        let to: Int
        /// What sits on the line's middle, which the layout gives a slot of its own.
        let label: String?
    }

    let direction: MermaidFlowchart.Direction
    /// Boxes and groups in one list, in first-mention order, which breaks the layout's ties.
    let nodes: [Node]
    let links: [Link]
}

/// A box graph, placed.
struct MermaidBoxDrawing: Equatable {
    struct Edge: Equatable {
        /// From the source's outline through any bends to the target's.
        let points: [MermaidPoint]
        let labelCenter: MermaidPoint
        /// A node's line to itself, drawn as a loop beside it.
        let isLoop: Bool

        var start: MermaidPoint { points[0] }
        var end: MermaidPoint { points[points.count - 1] }
    }

    let width: Double
    let height: Double
    /// Every node's frame, groups included.
    let frames: [MermaidRect]
    /// Where each group's title is centered, `nil` for a box.
    let titleCenters: [MermaidPoint?]
    /// One per link, in the graph's order.
    let edges: [Edge]
}

/// Boxes and groups merged into one first-mention order, and where each landed in it.
struct MermaidBoxOrder {
    /// A group or a box, by its index among its own kind.
    let items: [(isGroup: Bool, index: Int)]
    let boxAt: [Int]
    let groupAt: [Int]
}

extension MermaidBoxGraph {
    /// Boxes and groups merged into one first-mention order, each group just before the first box
    /// mentioned after it opened (its `position`).
    static func order(boxes: Int, groupPositions: [Int]) -> MermaidBoxOrder {
        var boxAt = [Int](repeating: 0, count: boxes)
        var groupAt = [Int](repeating: 0, count: groupPositions.count)
        var items: [(isGroup: Bool, index: Int)] = []
        for position in 0...boxes {
            for (index, start) in groupPositions.enumerated() where min(start, boxes) == position {
                groupAt[index] = items.count
                items.append((true, index))
            }
            if position < boxes {
                boxAt[position] = items.count
                items.append((false, position))
            }
        }
        return MermaidBoxOrder(items: items, boxAt: boxAt, groupAt: groupAt)
    }

    func lay(
        metric: MarkdownTextMetric,
        spacing: MermaidLayered.Spacing
    ) -> MermaidBoxDrawing {
        let (diagram, boxes) = stateDiagram()
        let drawing = MermaidStateLayout.lay(
            out: diagram,
            metric: metric,
            boxes: boxes,
            spacing: spacing
        )
        var edges = [MermaidBoxDrawing.Edge?](repeating: nil, count: links.count)
        for edge in drawing.edges where edge.transition < links.count {
            edges[edge.transition] = MermaidBoxDrawing.Edge(
                points: edge.points,
                labelCenter: edge.labelCenter,
                isLoop: edge.isLoop
            )
        }
        let frames = drawing.nodes.map(\.frame)
        return MermaidBoxDrawing(
            width: drawing.width,
            height: drawing.height,
            frames: frames,
            titleCenters: zip(nodes, drawing.nodes).map { node, drawn in
                node.isGroup ? drawn.texts.first?.center : nil
            },
            // Every transition comes back as an edge, ranked, looped or direct; the fallback is a
            // straight line between centers, so a gap in that promise would draw rather than crash.
            edges: links.indices.map { index in
                edges[index] ?? MermaidBoxDrawing.Edge(
                    points: [frames[links[index].from].center, frames[links[index].to].center],
                    labelCenter: frames[links[index].from].center,
                    isLoop: false
                )
            }
        )
    }

    /// The graph as a state diagram: one simple state per box, one composite per group with its
    /// members as its single region, one transition per link.
    private func stateDiagram() -> (MermaidStateDiagram, [Int: MermaidSize]) {
        var members = [[Int]](repeating: [], count: nodes.count)
        var top: [Int] = []
        for (index, node) in nodes.enumerated() {
            if let parent = node.parent, nodes.indices.contains(parent), nodes[parent].isGroup {
                members[parent].append(index)
            } else {
                top.append(index)
            }
        }
        var boxes: [Int: MermaidSize] = [:]
        let states = nodes.enumerated().map { index, node -> MermaidStateDiagram.State in
            if let box = node.box { boxes[index] = box }
            return MermaidStateDiagram.State(
                id: String(index),
                kind: .state,
                descriptions: [node.title],
                regions: node.isGroup ? [MermaidStateDiagram.Region(states: members[index])] : [],
                direction: node.isGroup ? flow(inside: index) : nil,
                notes: []
            )
        }
        let diagram = MermaidStateDiagram(
            direction: direction,
            states: states,
            regions: [MermaidStateDiagram.Region(states: top)],
            transitions: links.map {
                MermaidStateDiagram.Transition(from: $0.from, to: $0.to, label: $0.label)
            },
            undrawn: []
        )
        return (diagram, boxes)
    }

    /// The direction a group's inside runs in: its own, else the nearest enclosing group's, else
    /// the diagram's. Bounded by the node count, so a parent chain that loops cannot hang.
    private func flow(inside group: Int) -> MermaidFlowchart.Direction {
        var current: Int? = group
        var steps = 0
        while let index = current, nodes.indices.contains(index), steps <= nodes.count {
            if let direction = nodes[index].direction { return direction }
            current = nodes[index].parent
            steps += 1
        }
        return direction
    }
}
