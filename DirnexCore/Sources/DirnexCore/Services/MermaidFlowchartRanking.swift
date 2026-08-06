import Foundation

/// The layered graph a flowchart is drawn on (PLAN.md §M18 ▸ Slice 4).
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
}

/// Cycle-breaking, layering, dummy chains and ordering.
///
/// Split from the placement half because the two halves reason about different things: this one is
/// pure graph theory over `Int` ids and knows nothing about points, and `MermaidFlowchartLayout`
/// turns its answer into geometry.
enum MermaidFlowchartRanking {
    /// One edge, reduced to indices: which of the diagram's edges it is, and the two nodes it
    /// joins. A named type rather than a tuple because it is threaded through three passes, and
    /// `$0.1` versus `$0.2` is exactly the confusion a graph algorithm cannot afford.
    private struct Link {
        let position: Int
        let from: Int
        let to: Int
    }

    static func rank(_ chart: MermaidFlowchart, index: [String: Int]) -> MermaidRanking {
        let count = chart.nodes.count
        let links = chart.edges.enumerated().compactMap { position, edge -> Link? in
            guard let from = index[edge.from], let to = index[edge.to], from != to else {
                return nil
            }
            return Link(position: position, from: from, to: to)
        }
        let forward = acyclic(links, count: count)
        var layerOf = longestPath(forward, count: count)
        var chains = [[Int]](repeating: [], count: chart.edges.count)
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
            layers: order(layers, links: ordering),
            chains: chains,
            realCount: count,
            layerOf: layerOf
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

    /// One barycenter pass, downward: each node moves to the mean position of its predecessors.
    ///
    /// A node with no predecessor in the layer above keeps where it was — hence its own index as
    /// the fallback barycenter, which makes the sort a no-op for it rather than sending it to one
    /// end. The sort is stable, so declaration order still breaks every tie.
    ///
    /// One pass, not iterated to a fixed point: it is what uncrosses the common cases, and a dummy
    /// has exactly one predecessor, so a single pass already tracks each long edge under its source.
    private static func order(_ layers: [[Int]], links: [(Int, Int)]) -> [[Int]] {
        var predecessors: [Int: [Int]] = [:]
        for (from, to) in links { predecessors[to, default: []].append(from) }
        var result = layers
        guard result.count > 1 else { return result }
        for depth in 1..<result.count {
            var positions: [Int: Int] = [:]
            for (position, node) in result[depth - 1].enumerated() { positions[node] = position }
            let scored = result[depth].enumerated().map { position, node -> (Int, Double) in
                let above = (predecessors[node] ?? []).compactMap { positions[$0] }
                guard !above.isEmpty else { return (node, Double(position)) }
                return (node, above.reduce(0.0) { $0 + Double($1) } / Double(above.count))
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
}
