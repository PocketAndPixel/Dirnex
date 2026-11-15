import Foundation

/// A flowchart, placed (PLAN.md §M18 ▸ Slice 4).
struct MermaidFlowchartDrawing: Equatable {
    struct Node: Equatable {
        let label: String
        let shape: MermaidFlowchart.Shape
        let frame: MermaidRect
    }

    struct Edge: Equatable {
        /// The line, already clipped to both outlines — so the first point sits on the source's
        /// border and the last on the target's, which is where an arrowhead belongs.
        ///
        /// More than two points when the edge spans layers: it then bends through the dummies
        /// `MermaidLayering` reserved for it, which is what keeps a long edge out of the
        /// boxes between its ends.
        let points: [MermaidPoint]
        let label: String?
        let labelCenter: MermaidPoint
        let stroke: MermaidFlowchart.Stroke
        let tail: MermaidFlowchart.Tip
        let head: MermaidFlowchart.Tip
        /// A node's edge to itself, drawn as a loop beside it.
        var isLoop = false

        var start: MermaidPoint { points[0] }
        var end: MermaidPoint { points[points.count - 1] }
    }

    let width: Double
    let height: Double
    let nodes: [Node]
    let edges: [Edge]
}

/// Turning a ranked flowchart into geometry (PLAN.md §M18 ▸ Slice 4).
///
/// `MermaidLayering` has already decided which layer everything is in and what order it sits in
/// there, including the dummies that carry long edges, and `MermaidLayered` stacks the layers. What
/// is left is arithmetic: how big each box has to be and where a line crosses an outline.
///
/// Pure, and its one outside fact — how wide a label is — comes from an injected metric, so every
/// assertion in the tests is an exact number (`MarkdownTextMetric`).
enum MermaidFlowchartLayout {
    private static let spacing = MermaidLayered.Spacing(rankGap: 46, crossGap: 26, margin: 10)
    private static let padX = 12.0
    private static let padY = 8.0
    private static let minimumWidth = 36.0

    static func lay(
        out chart: MermaidFlowchart,
        metric: MarkdownTextMetric
    ) -> MermaidFlowchartDrawing {
        let index = Dictionary(
            uniqueKeysWithValues: chart.nodes.enumerated().map { ($1.id, $0) }
        )
        let ranking = MermaidLayering.rank(
            count: chart.nodes.count,
            edges: chart.edges.map { edge in
                guard let from = index[edge.from], let to = index[edge.to] else { return nil }
                return (from: from, to: to)
            }
        )
        let boxes = chart.nodes.map { size(of: $0, metric: metric) }
        let loops = loopLabels(chart, index: index)
        // A node with loops takes the room they need on both sides; every other node's slot is its
        // box, so a chart with no `A --> A` in it lays out exactly as it did before loops existed.
        var sizes = boxes.enumerated().map { node, box in
            MermaidSelfLoops.slot(
                box,
                labels: loops[node] ?? [],
                direction: chart.direction,
                metric: metric
            )
        }
        // A dummy is a point the line passes through, so it takes no depth along the rank axis and
        // just enough across it that the line clears its neighbors.
        sizes.append(contentsOf: repeatElement(
            MermaidSize(width: 1, height: 0),
            count: ranking.layerOf.count - ranking.realCount
        ))
        let slots = MermaidLayered.place(
            ranking.layers,
            sizes: sizes,
            direction: chart.direction,
            spacing: spacing
        ).frames
        let frames = slots.enumerated().map { node, slot in
            node < boxes.count ? centered(boxes[node], in: slot) : slot
        }
        return drawing(
            chart,
            ranking: ranking,
            placed: Placed(frames: frames, slots: slots, loops: loops),
            index: index,
            metric: metric
        )
    }

    /// What placement produced, carried into the drawing as one value.
    private struct Placed {
        let frames: [MermaidRect]
        let slots: [MermaidRect]
        /// Each looping node's loop labels, in the order its loops were written.
        let loops: [Int: [String?]]
    }

    // MARK: - Size

    /// A node's box, sized to hold its label.
    ///
    /// The two shapes that taper need more than padding, and the amount is geometry rather than
    /// taste: a rhombus of width `W` and height `H` contains a centered `w × h` box exactly when
    /// `w/W + h/H ≤ 1`, so doubling both dimensions is the smallest diamond that fits its text. A
    /// circle takes the longer of the two so it stays a circle.
    private static func size(
        of node: MermaidFlowchart.Node,
        metric: MarkdownTextMetric
    ) -> MermaidSize {
        let text = metric.width(node.label)
        let width = max(text + 2 * padX, minimumWidth)
        let height = metric.lineHeight + 2 * padY
        switch node.shape {
        case .circle:
            let diameter = max(width, height) * 1.15
            return MermaidSize(width: diameter, height: diameter)
        case .diamond:
            return MermaidSize(width: 2 * (text + padX), height: 2 * (metric.lineHeight + padY))
        case .subroutine:
            // Room for the two inner bars the shape draws.
            return MermaidSize(width: width + 16, height: height)
        case .rectangle, .rounded:
            return MermaidSize(width: width, height: height)
        }
    }

    /// Each node's self-edges' labels, keyed by node, in the order the file wrote them.
    private static func loopLabels(
        _ chart: MermaidFlowchart,
        index: [String: Int]
    ) -> [Int: [String?]] {
        var loops: [Int: [String?]] = [:]
        for edge in chart.edges where edge.from == edge.to {
            guard let node = index[edge.from] else { continue }
            loops[node, default: []].append(edge.label)
        }
        return loops
    }

    private static func centered(_ size: MermaidSize, in slot: MermaidRect) -> MermaidRect {
        MermaidRect(
            x: slot.x + (slot.width - size.width) / 2,
            y: slot.y + (slot.height - size.height) / 2,
            width: size.width,
            height: size.height
        )
    }

    // MARK: - The drawing

    private static func drawing(
        _ chart: MermaidFlowchart,
        ranking: MermaidRanking,
        placed: Placed,
        index: [String: Int],
        metric: MarkdownTextMetric
    ) -> MermaidFlowchartDrawing {
        let frames = placed.frames
        let nodes = zip(chart.nodes, frames).map {
            MermaidFlowchartDrawing.Node(label: $0.label, shape: $0.shape, frame: $1)
        }
        var loops = placed.loops.mapValues { _ in [MermaidSelfLoops.Loop]() }
        for (node, labels) in placed.loops {
            loops[node] = MermaidSelfLoops(
                frame: frames[node],
                shape: chart.nodes[node].shape,
                direction: chart.direction,
                labels: labels
            ).drawn(metric: metric)
        }
        var loopsUsed: [Int: Int] = [:]
        let edges = chart.edges.enumerated().compactMap { position, edge
            -> MermaidFlowchartDrawing.Edge? in
            guard let from = index[edge.from], let to = index[edge.to] else { return nil }
            guard from == to else {
                return self.edge(
                    edge,
                    chain: ranking.chains[position],
                    chart: chart,
                    frames: frames,
                    index: index
                )
            }
            let used = loopsUsed[from, default: 0]
            loopsUsed[from] = used + 1
            guard let loop = loops[from]?[used] else { return nil }
            return MermaidFlowchartDrawing.Edge(
                points: loop.points,
                label: edge.label,
                labelCenter: loop.labelCenter ?? middle(of: loop.points),
                stroke: edge.stroke,
                tail: edge.tail,
                head: edge.head,
                isLoop: true
            )
        }
        // Measured over what is **drawn**, which is not the same as over the diagram's own nodes: a
        // routed edge bends through dummies that sit outside every box, and sizing the canvas from
        // the boxes alone sent a back edge off the right-hand side of the picture and back. An edge
        // label reaches further still, since it is centered on a line rather than inside a shape,
        // and a node's loops reach as far as its slot.
        let reach = edges.flatMap(\.points) + nodes.flatMap {
            [MermaidPoint(x: $0.frame.maxX, y: $0.frame.maxY)]
        } + placed.loops.keys.map {
            MermaidPoint(x: placed.slots[$0].maxX, y: placed.slots[$0].maxY)
        }
        return MermaidFlowchartDrawing(
            width: max(
                reach.map(\.x).max().map { $0 + spacing.margin } ?? 0,
                labelReach(edges, metric: metric)
            ),
            height: reach.map(\.y).max().map { $0 + spacing.margin } ?? 0,
            nodes: nodes,
            edges: edges
        )
    }

    private static func edge(
        _ edge: MermaidFlowchart.Edge,
        chain: [Int],
        chart: MermaidFlowchart,
        frames: [MermaidRect],
        index: [String: Int]
    ) -> MermaidFlowchartDrawing.Edge? {
        guard let from = index[edge.from], let to = index[edge.to] else { return nil }
        let waypoints = chain.map { frames[$0].center }
        let start = MermaidOutline.boundary(
            of: frames[from],
            shape: chart.nodes[from].shape,
            toward: waypoints.first ?? frames[to].center
        )
        let end = MermaidOutline.boundary(
            of: frames[to],
            shape: chart.nodes[to].shape,
            toward: waypoints.last ?? frames[from].center
        )
        let points = [start] + waypoints + [end]
        return MermaidFlowchartDrawing.Edge(
            points: points,
            label: edge.label,
            labelCenter: middle(of: points),
            stroke: edge.stroke,
            tail: edge.tail,
            head: edge.head
        )
    }

    /// The midpoint of the polyline's **middle segment**, which for a straight edge is its center
    /// and for a bent one is a place the label can actually sit. Measuring along arc length instead
    /// would put a label on a corner.
    private static func middle(of points: [MermaidPoint]) -> MermaidPoint {
        let index = (points.count - 1) / 2
        let first = points[index]
        let second = points[index + 1]
        return MermaidPoint(x: (first.x + second.x) / 2, y: (first.y + second.y) / 2)
    }

    /// How far right the widest edge label reaches.
    ///
    /// The canvas has to hold it: a label centered between two layers can be wider than either of
    /// them, and one clipped at the edge of the SVG reads as a bug in the diagram rather than in
    /// its box.
    private static func labelReach(
        _ edges: [MermaidFlowchartDrawing.Edge],
        metric: MarkdownTextMetric
    ) -> Double {
        edges.reduce(0.0) { widest, edge in
            guard let label = edge.label else { return widest }
            return max(widest, edge.labelCenter.x + metric.width(label) / 2 + spacing.margin)
        }
    }
}
