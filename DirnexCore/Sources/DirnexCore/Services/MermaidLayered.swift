import Foundation

/// A width and a height, which is all a layer needs to know about what it holds.
struct MermaidSize: Equatable {
    var width: Double
    var height: Double
}

/// A ranked graph's layers, turned into frames (PLAN.md §M18 ▸ Slice 4, shared since §M39 ▸
/// Slice 13).
///
/// The flowchart's placement, lifted out unchanged when the state diagram arrived to use it: layers
/// stacked along the rank axis, each centered against the widest, mapped to x and y at the end. The
/// distances are the caller's (`Spacing`), since a state diagram's half-layers want a tighter rank
/// gap than a flowchart's whole ones.
enum MermaidLayered {
    struct Spacing: Equatable {
        /// Between consecutive layers.
        let rankGap: Double
        /// Between neighbors within a layer.
        let crossGap: Double
        /// Around the whole.
        let margin: Double
    }

    /// What a balanced placement lines up: the segments joining neighboring layers, and where on
    /// each slot a segment attaches across the flow, as an offset from the slot's center — not zero
    /// for a state whose note sits beside it, since it is the state that should line up.
    struct Balance {
        let segments: [(upper: Int, lower: Int)]
        let anchors: [Double]
        /// Alternating downward and upward sweeps.
        let sweeps: Int
    }

    /// Every virtual node's frame, and the size of the canvas they were placed on.
    struct Placement: Equatable {
        let frames: [MermaidRect]
        let width: Double
        let height: Double
    }

    /// Written once in rank/cross terms and mapped to x/y at the end, because the four directions
    /// are two axes and a flip rather than four layouts — which is what `Direction.isHorizontal`
    /// and `.isReversed` exist to say.
    ///
    /// Without a `balance` each layer is centered against the widest, the flowchart's placement.
    /// With one, each node then moves toward the nodes it is joined to (`balanced`).
    static func place(
        _ layers: [[Int]],
        sizes: [MermaidSize],
        direction: MermaidFlowchart.Direction,
        spacing: Spacing,
        balance: Balance? = nil
    ) -> Placement {
        let horizontal = direction.isHorizontal
        func rankExtent(_ node: Int) -> Double { horizontal ? sizes[node].width : sizes[node].height }
        func crossExtent(_ node: Int) -> Double { horizontal ? sizes[node].height : sizes[node].width }

        let depths = layers.map { layer in layer.map(rankExtent).max() ?? 0 }
        let spans = layers.map { layer in
            layer.map(crossExtent).reduce(0, +)
                + spacing.crossGap * Double(max(layer.count - 1, 0))
        }
        let widest = spans.max() ?? 0
        let totalRank = depths.reduce(0, +) + spacing.rankGap * Double(max(depths.count - 1, 0))

        var crosses = [Double](repeating: 0, count: sizes.count)
        var ranks = [Double](repeating: 0, count: sizes.count)
        var rank = spacing.margin
        for (depth, layer) in layers.enumerated() {
            var cross = spacing.margin + (widest - spans[depth]) / 2
            for node in layer {
                ranks[node] = rank + (depths[depth] - rankExtent(node)) / 2
                crosses[node] = cross
                cross += crossExtent(node) + spacing.crossGap
            }
            rank += depths[depth] + spacing.rankGap
        }
        var span = widest
        if let balance {
            let extents = sizes.indices.map(crossExtent)
            crosses = balanced(
                crosses,
                layers: layers,
                extents: extents,
                gap: spacing.crossGap,
                balance
            )
            let low = crosses.min() ?? spacing.margin
            let high = zip(crosses, extents).map { $0 + $1 }.max() ?? spacing.margin
            crosses = crosses.map { $0 - low + spacing.margin }
            span = high - low
        }
        let frames = sizes.indices.map { node in
            let size = sizes[node]
            return horizontal
                ? MermaidRect(
                    x: ranks[node],
                    y: crosses[node],
                    width: size.width,
                    height: size.height
                )
                : MermaidRect(
                    x: crosses[node],
                    y: ranks[node],
                    width: size.width,
                    height: size.height
                )
        }
        let width = (horizontal ? totalRank : span) + 2 * spacing.margin
        let height = (horizontal ? span : totalRank) + 2 * spacing.margin
        return Placement(
            frames: flipped(frames, direction: direction, width: width, height: height),
            width: width,
            height: height
        )
    }

    /// Each layer's nodes moved toward what they are joined to, keeping their order and their gaps.
    ///
    /// Centering each layer on its own is fine for a flowchart's whole layers, and wrong once every
    /// edge has a dummy of its own: a long transition then zig-zagged from one side of the picture
    /// to the other as each layer centered its dummies differently. So each sweep asks every node
    /// in a layer where its neighbors in the layer just placed attach, on average, and puts the
    /// layer as close to that as its order and gaps allow — which is isotonic regression once each
    /// node's position is measured less the room the nodes before it need, solved exactly by
    /// pooling adjacent violators.
    private static func balanced(
        _ start: [Double],
        layers: [[Int]],
        extents: [Double],
        gap: Double,
        _ balance: Balance
    ) -> [Double] {
        var crosses = start
        var above = [[Int]](repeating: [], count: start.count)
        var below = [[Int]](repeating: [], count: start.count)
        for segment in balance.segments
            where segment.upper < start.count && segment.lower < start.count {
            above[segment.lower].append(segment.upper)
            below[segment.upper].append(segment.lower)
        }
        func anchor(_ node: Int) -> Double {
            crosses[node] + extents[node] / 2 + balance.anchors[node]
        }
        for pass in 0..<balance.sweeps {
            let downward = pass % 2 == 0
            let order = downward ? Array(layers.dropFirst()) : Array(layers.dropLast().reversed())
            for layer in order {
                var room = 0.0
                var targets: [Double] = []
                for node in layer {
                    let near = downward ? above[node] : below[node]
                    let wanted = near.isEmpty
                        ? anchor(node)
                        : near.map(anchor).reduce(0, +) / Double(near.count)
                    targets.append(wanted - extents[node] / 2 - balance.anchors[node] - room)
                    room += extents[node] + gap
                }
                var offset = 0.0
                for (node, value) in zip(layer, nondecreasing(targets)) {
                    crosses[node] = value + offset
                    offset += extents[node] + gap
                }
            }
        }
        return crosses
    }

    /// The nondecreasing sequence closest to `values` in squares: runs that fall are pooled into
    /// their mean until nothing falls.
    private static func nondecreasing(_ values: [Double]) -> [Double] {
        var blocks: [(mean: Double, count: Int)] = []
        for value in values {
            blocks.append((value, 1))
            while blocks.count > 1, blocks[blocks.count - 2].mean > blocks[blocks.count - 1].mean {
                let last = blocks.removeLast()
                let previous = blocks.removeLast()
                let count = previous.count + last.count
                blocks.append((
                    (previous.mean * Double(previous.count) + last.mean * Double(last.count))
                        / Double(count),
                    count
                ))
            }
        }
        return blocks.flatMap { repeatElement($0.mean, count: $0.count) }
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
}

/// The edges from one node back to itself, drawn as loops beside it (PLAN.md §M39 ▸ Slice 13).
///
/// A state diagram's `a --> a : retry` is common, and a flowchart's `A --> A` had drawn nothing at
/// all since M18 — a zero-length edge has no direction to clip or aim — so both now take this. The
/// loop leaves the node on the side across the flow (the right in a vertical diagram, the bottom in
/// a horizontal one), runs out and back, and comes home with its tip pointing into the node. Several
/// loops on one node nest, each a step further out, with their labels stacked beyond the last.
///
/// The room is reserved **on both sides**, which looks like waste and is the point: the placement
/// centers each layer, so a node widened on one side only would leave its column, and every straight
/// edge above and below it would lean.
struct MermaidSelfLoops {
    private static let firstReach = 16.0
    private static let reachStep = 12.0
    private static let firstSpread = 5.0
    private static let spreadStep = 7.0
    private static let labelGap = 6.0

    let frame: MermaidRect
    let shape: MermaidFlowchart.Shape
    let direction: MermaidFlowchart.Direction
    /// Each loop's label, `nil` for one that has none.
    let labels: [String?]

    /// One loop, as a polyline from the node's outline and back to it, and where its label is
    /// centered when it has one.
    struct Loop {
        let points: [MermaidPoint]
        let labelCenter: MermaidPoint?
    }

    func drawn(metric: MarkdownTextMetric) -> [Loop] {
        var labeled = 0
        return labels.enumerated().map { index, label in
            let center = label.map { labelCenter(text: $0, at: labeled, metric: metric) }
            if label != nil { labeled += 1 }
            return Loop(points: points(index), labelCenter: center)
        }
    }

    private func points(_ index: Int) -> [MermaidPoint] {
        let reach = Self.firstReach + Self.reachStep * Double(index)
        if direction.isHorizontal {
            let spread = min(Self.firstSpread + Self.spreadStep * Double(index), frame.width / 2 - 1)
            let left = frame.midX - spread
            let right = frame.midX + spread
            return [
                MermaidPoint(x: left, y: MermaidOutline.bottom(of: frame, shape: shape, atX: left)),
                MermaidPoint(x: left, y: frame.maxY + reach),
                MermaidPoint(x: right, y: frame.maxY + reach),
                MermaidPoint(x: right, y: MermaidOutline.bottom(of: frame, shape: shape, atX: right))
            ]
        }
        let spread = min(Self.firstSpread + Self.spreadStep * Double(index), frame.height / 2 - 1)
        let top = frame.midY - spread
        let bottom = frame.midY + spread
        return [
            MermaidPoint(x: MermaidOutline.right(of: frame, shape: shape, atY: top), y: top),
            MermaidPoint(x: frame.maxX + reach, y: top),
            MermaidPoint(x: frame.maxX + reach, y: bottom),
            MermaidPoint(x: MermaidOutline.right(of: frame, shape: shape, atY: bottom), y: bottom)
        ]
    }

    /// The `position`-th label, stacked beyond the outermost loop, one line each.
    private func labelCenter(
        text: String,
        at position: Int,
        metric: MarkdownTextMetric
    ) -> MermaidPoint {
        let outer = Self.firstReach + Self.reachStep * Double(max(labels.count - 1, 0)) + Self.labelGap
        if direction.isHorizontal {
            return MermaidPoint(
                x: frame.midX,
                y: frame.maxY + outer + metric.lineHeight * (Double(position) + 0.5)
            )
        }
        let stack = metric.lineHeight * Double(labels.compactMap(\.self).count)
        return MermaidPoint(
            x: frame.maxX + outer + metric.width(text) / 2,
            y: frame.midY - stack / 2 + metric.lineHeight * (Double(position) + 0.5)
        )
    }

    /// The room a node of `size` takes once its loops are drawn, with the node centered in it.
    ///
    /// The loops and their labels reach out on one side, and the same is reserved on the other; a
    /// label wider or a stack of labels taller than the node widens the slot along the other axis
    /// too, so nothing a neighbor draws can run into it.
    static func slot(
        _ size: MermaidSize,
        labels: [String?],
        direction: MermaidFlowchart.Direction,
        metric: MarkdownTextMetric
    ) -> MermaidSize {
        guard !labels.isEmpty else { return size }
        let loops = Self.firstReach + Self.reachStep * Double(labels.count - 1) + 2
        let texts = labels.compactMap(\.self)
        let widest = texts.map(metric.width).max() ?? 0
        let stack = metric.lineHeight * Double(texts.count)
        if direction.isHorizontal {
            let reach = loops + (texts.isEmpty ? 0 : labelGap + stack)
            return MermaidSize(width: max(size.width, widest + 4), height: size.height + 2 * reach)
        }
        let reach = loops + (texts.isEmpty ? 0 : labelGap + widest + 4)
        return MermaidSize(width: size.width + 2 * reach, height: max(size.height, stack))
    }
}

extension MermaidOutline {
    /// Where the outline's right-hand side is at height `y`, for a loop leaving sideways. A
    /// rectangle's is its edge wherever you ask; an ellipse and a rhombus draw in toward the center
    /// as `y` leaves the middle, and a loop started at the bounding box would float off them.
    static func right(of frame: MermaidRect, shape: MermaidFlowchart.Shape, atY y: Double) -> Double {
        frame.midX + frame.width / 2 * reach(shape, offset: (y - frame.midY) / (frame.height / 2))
    }

    /// The same, for the bottom side at `x`.
    static func bottom(of frame: MermaidRect, shape: MermaidFlowchart.Shape, atX x: Double) -> Double {
        frame.midY + frame.height / 2 * reach(shape, offset: (x - frame.midX) / (frame.width / 2))
    }

    /// How far out the outline is, as a fraction of the half-extent, at a normalized offset along
    /// the other axis.
    private static func reach(_ shape: MermaidFlowchart.Shape, offset: Double) -> Double {
        let along = min(abs(offset), 1)
        switch shape {
        case .circle: return (1 - along * along).squareRoot()
        case .diamond: return 1 - along
        case .rectangle, .rounded, .subroutine: return 1
        }
    }
}
