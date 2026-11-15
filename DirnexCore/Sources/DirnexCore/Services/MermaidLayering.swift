import Foundation

/// The layered graph a diagram is drawn on (PLAN.md §M18 ▸ Slice 4, shared since §M39 ▸ Slice 13).
///
/// Carries **more nodes than the diagram has**: an edge spanning several layers gets one *dummy*
/// node in each layer it crosses, so the ordering pass can steer it between the real nodes instead
/// of through them. That is the one piece of Sugiyama layering it is not worth skipping — the first
/// build without it drew `F ==> A` as a straight line through four boxes and two edge labels, which
/// is not a diagram anybody can read.
struct MermaidRanking {
    /// Virtual node ids, by layer, in drawing order. An id below `realCount` is one of the
    /// diagram's own nodes; the rest are dummies.
    let layers: [[Int]]
    /// Per original edge, the dummies strictly between its endpoints, in **from → to** order — so
    /// a back edge's chain reads the way its arrow points, not the way the layers run.
    let chains: [[Int]]
    let realCount: Int
    /// Every virtual node's layer, indexed by id.
    let layerOf: [Int]
    /// Every piece of every edge once the dummies are in, upper end first: each joins two
    /// neighboring layers, and it is what a balanced placement lines up (`MermaidLayered`).
    let segments: [(upper: Int, lower: Int)]
}

/// Cycle-breaking, layering, dummy chains and ordering.
///
/// Split from the placement half because the two halves reason about different things: this one is
/// pure graph theory over `Int` ids and knows nothing about points, and `MermaidLayered` turns its
/// answer into geometry. It knows nothing about which dialect it serves either, which is what let
/// the state diagram take it whole (§M39 ▸ Slice 13): a flowchart hands over its nodes and edges, a
/// state diagram one region's states and transitions.
enum MermaidLayering {
    /// One edge, reduced to indices: which of the diagram's edges it is, and the two nodes it
    /// joins. A named type rather than a tuple because it is threaded through three passes, and
    /// `$0.1` versus `$0.2` is exactly the confusion a graph algorithm cannot afford.
    private struct Link {
        let position: Int
        let from: Int
        let to: Int
    }

    /// `count` nodes and the edges between them, layered.
    ///
    /// An edge is `nil` when it joins nothing drawable — an unknown id, or a node to itself, which
    /// takes no part in layering — and keeps its position so `chains` still lines up with the
    /// caller's edges.
    ///
    /// `stride` spaces the real nodes' layers apart. At `2` every edge crosses at least one layer
    /// of its own, so every edge gets a dummy there, and a dummy can be given its label's size: two
    /// labeled edges between the same pair of nodes then sit side by side in that layer instead of
    /// on top of each other, which is dagre's answer and the state diagram's (`A --> B : x` and
    /// `B --> A : y` are the norm there). The flowchart keeps `1`, the layout it shipped with.
    static func rank(
        count: Int,
        edges: [(from: Int, to: Int)?],
        stride: Int = 1,
        sweeps: Int = 1
    ) -> MermaidRanking {
        let links = edges.enumerated().compactMap { position, edge -> Link? in
            guard let edge, edge.from != edge.to else { return nil }
            return Link(position: position, from: edge.from, to: edge.to)
        }
        let forward = acyclic(links, count: count)
        var layerOf = longestPath(forward, count: count).map { $0 * max(stride, 1) }
        var chains = [[Int]](repeating: [], count: edges.count)
        var ordering: [(Int, Int)] = []

        for link in links {
            let (from, to) = (link.from, link.to)
            let start = layerOf[from]
            let end = layerOf[to]
            guard abs(start - end) > 1 else {
                // Adjacent layers need no dummy, and a same-layer edge must not become an ordering
                // constraint — it would be a cycle in a graph whose whole point is not having one.
                if start != end { ordering.append(start < end ? (from, to) : (to, from)) }
                continue
            }
            var chain: [Int] = []
            for layer in (min(start, end) + 1)..<max(start, end) {
                chain.append(layerOf.count)
                layerOf.append(layer)
            }
            var previous = start < end ? from : to
            for node in chain {
                ordering.append((previous, node))
                previous = node
            }
            ordering.append((previous, start < end ? to : from))
            chains[link.position] = start < end ? chain : chain.reversed()
        }

        let depth = (layerOf.max() ?? 0) + 1
        var layers = [[Int]](repeating: [], count: depth)
        for node in layerOf.indices { layers[layerOf[node]].append(node) }
        return MermaidRanking(
            layers: order(layers, links: ordering, sweeps: sweeps),
            chains: chains,
            realCount: count,
            layerOf: layerOf,
            segments: ordering
        )
    }

    // MARK: - Cycles

    /// `links` with every back edge removed, found by one DFS in declaration order.
    ///
    /// "On the current stack" is the test — an edge to a node we are still descending through
    /// closes a cycle. Visiting roots in declaration order is what makes the result deterministic:
    /// a different starting node breaks a different edge of the same cycle, and the drawing would
    /// otherwise depend on hash order.
    ///
    /// Not an optimization. Longest-path layering does not terminate on a cycle, so without this a
    /// `.md` containing `A --> B --> A` would hang the preview of a file a cursor passed over.
    private static func acyclic(_ links: [Link], count: Int) -> [(Int, Int)] {
        var successors = [[Int]](repeating: [], count: count)
        for link in links { successors[link.from].append(link.to) }
        var state = [Int](repeating: 0, count: count) // 0 unseen, 1 on stack, 2 done
        var back: Set<Int> = []

        func visit(_ node: Int) {
            state[node] = 1
            for next in successors[node] {
                if state[next] == 1 {
                    back.insert(node * count + next)
                } else if state[next] == 0 {
                    visit(next)
                }
            }
            state[node] = 2
        }
        for node in 0..<count where state[node] == 0 { visit(node) }
        return links.compactMap {
            back.contains($0.from * count + $0.to) ? nil : ($0.from, $0.to)
        }
    }

    // MARK: - Layers

    /// Longest-path layering by Kahn's order: every node sits one below its **deepest** predecessor,
    /// so no edge ever points backwards or sideways in the acyclic graph.
    private static func longestPath(_ links: [(Int, Int)], count: Int) -> [Int] {
        var successors = [[Int]](repeating: [], count: count)
        var indegree = [Int](repeating: 0, count: count)
        for (from, to) in links {
            successors[from].append(to)
            indegree[to] += 1
        }
        var layer = [Int](repeating: 0, count: count)
        var queue = (0..<count).filter { indegree[$0] == 0 }
        var head = 0
        while head < queue.count {
            let node = queue[head]
            head += 1
            for next in successors[node] {
                layer[next] = max(layer[next], layer[node] + 1)
                indegree[next] -= 1
                if indegree[next] == 0 { queue.append(next) }
            }
        }
        return layer
    }

    // MARK: - Order within a layer

    /// Barycenter passes: each node moves to the mean position of its neighbors in the layer just
    /// swept from.
    ///
    /// A node with no neighbor there keeps where it was — hence its own index as the fallback
    /// barycenter, which makes the sort a no-op for it rather than sending it to one end. The sort
    /// is stable, so declaration order still breaks every tie.
    ///
    /// The flowchart takes **one pass, downward**: it is what uncrosses the common cases, and a
    /// dummy has exactly one predecessor, so a single pass already tracks each long edge under its
    /// source. A state diagram's half-layers and back edges cross far more (undici's lifecycle
    /// crossed itself into a knot), so it asks for `sweeps` alternating down and up, and keeps the
    /// ordering with the fewest crossings any of them reached.
    private static func order(_ layers: [[Int]], links: [(Int, Int)], sweeps: Int) -> [[Int]] {
        var predecessors: [Int: [Int]] = [:]
        var successors: [Int: [Int]] = [:]
        for (from, to) in links {
            predecessors[to, default: []].append(from)
            successors[from, default: []].append(to)
        }
        guard layers.count > 1 else { return layers }
        var result = sweep(layers, neighbors: predecessors, downward: true)
        guard sweeps > 1 else { return result }
        var best = result
        var fewest = crossings(result, links: links)
        for pass in 1..<sweeps where fewest > 0 {
            let downward = pass % 2 == 0
            result = sweep(
                result,
                neighbors: downward ? predecessors : successors,
                downward: downward
            )
            let count = crossings(result, links: links)
            if count < fewest {
                best = result
                fewest = count
            }
        }
        return best
    }

    private static func sweep(
        _ layers: [[Int]],
        neighbors: [Int: [Int]],
        downward: Bool
    ) -> [[Int]] {
        var result = layers
        let depths = downward
            ? Array(1..<result.count)
            : Array((0..<(result.count - 1)).reversed())
        for depth in depths {
            var positions: [Int: Int] = [:]
            for (position, node) in result[downward ? depth - 1 : depth + 1].enumerated() {
                positions[node] = position
            }
            let scored = result[depth].enumerated().map { position, node -> (Int, Double) in
                let near = (neighbors[node] ?? []).compactMap { positions[$0] }
                guard !near.isEmpty else { return (node, Double(position)) }
                return (node, near.reduce(0.0) { $0 + Double($1) } / Double(near.count))
            }
            result[depth] = scored
                .enumerated()
                .sorted { left, right in
                    left.element.1 == right.element.1
                        ? left.offset < right.offset
                        : left.element.1 < right.element.1
                }
                .map(\.element.0)
        }
        return result
    }

    /// How many pairs of segments cross between neighboring layers. Every link joins neighboring
    /// layers once the dummies are in, so two of them cross exactly when their ends are in opposite
    /// orders.
    private static func crossings(_ layers: [[Int]], links: [(Int, Int)]) -> Int {
        var position: [Int: Int] = [:]
        var layerOf: [Int: Int] = [:]
        for (depth, layer) in layers.enumerated() {
            for (index, node) in layer.enumerated() {
                position[node] = index
                layerOf[node] = depth
            }
        }
        var byLayer: [Int: [(Int, Int)]] = [:]
        for (from, to) in links {
            guard let top = position[from], let bottom = position[to] else { continue }
            byLayer[layerOf[from] ?? 0, default: []].append((top, bottom))
        }
        var count = 0
        for segments in byLayer.values {
            for first in segments.indices {
                for second in segments.indices where second > first {
                    let (top, bottom) = segments[first]
                    let (otherTop, otherBottom) = segments[second]
                    if (top < otherTop && bottom > otherBottom)
                        || (top > otherTop && bottom < otherBottom) { count += 1 }
                }
            }
        }
        return count
    }
}
