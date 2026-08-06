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
        /// `MermaidFlowchartRanking` reserved for it, which is what keeps a long edge out of the
        /// boxes between its ends.
        let points: [MermaidPoint]
        let label: String?
        let labelCentre: MermaidPoint
        let stroke: MermaidFlowchart.Stroke
        let tail: MermaidFlowchart.Tip
        let head: MermaidFlowchart.Tip

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
/// `MermaidFlowchartRanking` has already decided which layer everything is in and what order it
/// sits in there, including the dummies that carry long edges. What is left is arithmetic: how big
/// each box has to be, where each layer starts, and where a line crosses an outline.
///
/// Pure, and its one outside fact — how wide a label is — comes from an injected metric, so every
/// assertion in the tests is an exact number (`MarkdownTextMetric`).
enum MermaidFlowchartLayout {
    private static let rankGap = 46.0
    private static let crossGap = 26.0
    private static let margin = 10.0
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
        let ranking = MermaidFlowchartRanking.rank(chart, index: index)
        // A dummy is a point the line passes through, so it takes no depth along the rank axis and
        // just enough across it that the line clears its neighbours.
        var sizes = chart.nodes.map { size(of: $0, metric: metric) }
        sizes.append(contentsOf: repeatElement(
            (width: 1.0, height: 0.0),
            count: ranking.layerOf.count - ranking.realCount
        ))
        let frames = place(ranking.layers, sizes: sizes, direction: chart.direction)
        return drawing(chart, ranking: ranking, frames: frames, index: index, metric: metric)
    }

    // MARK: - Size

    /// A node's box, sized to hold its label.
    ///
    /// The two shapes that taper need more than padding, and the amount is geometry rather than
    /// taste: a rhombus of width `W` and height `H` contains a centred `w × h` box exactly when
    /// `w/W + h/H ≤ 1`, so doubling both dimensions is the smallest diamond that fits its text. A
    /// circle takes the longer of the two so it stays a circle.
    private static func size(
        of node: MermaidFlowchart.Node,
        metric: MarkdownTextMetric
    ) -> (width: Double, height: Double) {
        let text = metric.width(node.label)
        let width = max(text + 2 * padX, minimumWidth)
        let height = metric.lineHeight + 2 * padY
        switch node.shape {
        case .circle:
            let diameter = max(width, height) * 1.15
            return (diameter, diameter)
        case .diamond:
            return (2 * (text + padX), 2 * (metric.lineHeight + padY))
        case .subroutine:
            // Room for the two inner bars the shape draws.
            return (width + 16, height)
        case .rectangle, .rounded:
            return (width, height)
        }
    }

    // MARK: - Position

    /// Layers stacked along the rank axis, each centred against the widest.
    ///
    /// Written once in rank/cross terms and mapped to x/y at the end, because the four directions
    /// are two axes and a flip rather than four layouts — which is what `Direction.isHorizontal`
    /// and `.isReversed` exist to say.
    private static func place(
        _ layers: [[Int]],
        sizes: [(width: Double, height: Double)],
        direction: MermaidFlowchart.Direction
    ) -> [MermaidRect] {
        let horizontal = direction.isHorizontal
        func rankExtent(_ node: Int) -> Double { horizontal ? sizes[node].width : sizes[node].height }
        func crossExtent(_ node: Int) -> Double { horizontal ? sizes[node].height : sizes[node].width }

        let depths = layers.map { layer in layer.map(rankExtent).max() ?? 0 }
        let spans = layers.map { layer in
            layer.map(crossExtent).reduce(0, +) + crossGap * Double(max(layer.count - 1, 0))
        }
        let widest = spans.max() ?? 0
        let totalRank = depths.reduce(0, +) + rankGap * Double(max(depths.count - 1, 0))

        var frames = [MermaidRect](
            repeating: MermaidRect(x: 0, y: 0, width: 0, height: 0),
            count: sizes.count
        )
        var rank = margin
        for (depth, layer) in layers.enumerated() {
            var cross = margin + (widest - spans[depth]) / 2
            for node in layer {
                let alongRank = rank + (depths[depth] - rankExtent(node)) / 2
                let size = sizes[node]
                frames[node] = horizontal
                    ? MermaidRect(x: alongRank, y: cross, width: size.width, height: size.height)
                    : MermaidRect(x: cross, y: alongRank, width: size.width, height: size.height)
                cross += crossExtent(node) + crossGap
            }
            rank += depths[depth] + rankGap
        }
        return flipped(
            frames,
            direction: direction,
            width: (horizontal ? totalRank : widest) + 2 * margin,
            height: (horizontal ? widest : totalRank) + 2 * margin
        )
    }

    /// `RL` and `BT` are their twins mirrored on the rank axis. Doing it here rather than in the
    /// placement loop is what keeps one placement for four directions.
    private static func flipped(
        _ frames: [MermaidRect],
        direction: MermaidFlowchart.Direction,
        width: Double,
        height: Double
    ) -> [MermaidRect] {
        guard direction.isReversed else { return frames }
        return frames.map { frame in
            direction.isHorizontal
                ? MermaidRect(
                    x: width - frame.maxX,
                    y: frame.y,
                    width: frame.width,
                    height: frame.height
                )
                : MermaidRect(
                    x: frame.x,
                    y: height - frame.maxY,
                    width: frame.width,
                    height: frame.height
                )
        }
    }

    // MARK: - The drawing

    private static func drawing(
        _ chart: MermaidFlowchart,
        ranking: MermaidRanking,
        frames: [MermaidRect],
        index: [String: Int],
        metric: MarkdownTextMetric
    ) -> MermaidFlowchartDrawing {
        let nodes = zip(chart.nodes, frames).map {
            MermaidFlowchartDrawing.Node(label: $0.label, shape: $0.shape, frame: $1)
        }
        let edges = chart.edges.enumerated().compactMap { position, edge in
            self.edge(
                edge,
                chain: ranking.chains[position],
                chart: chart,
                frames: frames,
                index: index
            )
        }
        // Measured over what is **drawn**, which is not the same as over the diagram's own nodes: a
        // routed edge bends through dummies that sit outside every box, and sizing the canvas from
        // the boxes alone sent a back edge off the right-hand side of the picture and back. An edge
        // label reaches further still, since it is centred on a line rather than inside a shape.
        let reach = edges.flatMap(\.points) + nodes.flatMap {
            [MermaidPoint(x: $0.frame.maxX, y: $0.frame.maxY)]
        }
        return MermaidFlowchartDrawing(
            width: max(
                reach.map(\.x).max().map { $0 + margin } ?? 0,
                labelReach(edges, metric: metric)
            ),
            height: reach.map(\.y).max().map { $0 + margin } ?? 0,
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
        guard let from = index[edge.from], let to = index[edge.to], from != to else { return nil }
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
            labelCentre: middle(of: points),
            stroke: edge.stroke,
            tail: edge.tail,
            head: edge.head
        )
    }

    /// The midpoint of the polyline's **middle segment**, which for a straight edge is its centre
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
    /// The canvas has to hold it: a label centred between two layers can be wider than either of
    /// them, and one clipped at the edge of the SVG reads as a bug in the diagram rather than in
    /// its box.
    private static func labelReach(
        _ edges: [MermaidFlowchartDrawing.Edge],
        metric: MarkdownTextMetric
    ) -> Double {
        edges.reduce(0.0) { widest, edge in
            guard let label = edge.label else { return widest }
            return max(widest, edge.labelCentre.x + metric.width(label) / 2 + margin)
        }
    }
}
