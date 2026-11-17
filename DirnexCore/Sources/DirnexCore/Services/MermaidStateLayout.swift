import Foundation

/// A state diagram, placed (PLAN.md §M39 ▸ Slice 13).
struct MermaidStateDrawing: Equatable {
    /// One line of text and where its center goes. The layout places every line, because only the
    /// layout has the metric that says how tall a line is.
    struct Text: Equatable {
        let string: String
        let center: MermaidPoint
    }

    struct Node: Equatable {
        let kind: MermaidStateDiagram.Kind
        let frame: MermaidRect
        /// What the box says, a line each: its title, then any further descriptions under a rule.
        /// Empty for a start, an end, a choice and a bar.
        let texts: [Text]
        let isComposite: Bool
        /// Where the rule under the title runs, for a composite or a box with lines under its title.
        let ruleY: Double?
    }

    struct Note: Equatable {
        let frame: MermaidRect
        let texts: [Text]
        /// The dashed line from the note to its state.
        let link: [MermaidPoint]
    }

    struct Edge: Equatable {
        /// Clipped to both outlines, bending through the dummies the ranking reserved, one of which
        /// is where the label sits.
        let points: [MermaidPoint]
        let label: String?
        let labelCenter: MermaidPoint
        /// Which of the diagram's transitions this is, since the edges come out ranked ones first,
        /// then loops, then direct ones, and a caller drawing more than a line needs to know whose.
        let transition: Int
        /// A state's transition to itself, drawn as a loop beside it.
        var isLoop = false

        var start: MermaidPoint { points[0] }
        var end: MermaidPoint { points[points.count - 1] }
    }

    let width: Double
    let height: Double
    /// One per state, in the diagram's order.
    let nodes: [Node]
    let notes: [Note]
    let edges: [Edge]
    /// The dashed lines between a composite's regions (or the whole diagram's), two points each.
    let dividers: [[MermaidPoint]]
}

/// Placing a state diagram (PLAN.md §M39 ▸ Slice 13).
///
/// **The flowchart's layered layout, once per region, from the inside out.** A composite state's
/// inside is laid out first, on its own, and the composite then takes part in its parent's region as
/// one box that size — so a composite is never a frame drawn around wherever its children happened
/// to land, which is the problem a single flat layout would have. Mermaid's docs allow transitions
/// only within one region and to a composite as a whole, and with that rule the recursion is exact.
///
/// A transition that crosses a border anyway (`x --> inner1`, which Mermaid draws) is laid out in
/// the innermost region holding both ends, between the states there that contain them, and then
/// **drawn to the real states**: the line leaves the box it starts in and crosses into the composite
/// to reach the state inside, as Mermaid shows it (Oleg's call, 2026-11-15).
///
/// Two departures from the flowchart, both for what state diagrams are full of: every transition
/// gets a half-layer slot sized to its label (`MermaidLayering`'s `stride`), so `A --> B : x` and
/// `B --> A : y` draw side by side rather than as one line with two labels on it; and a state's
/// slot holds its notes and its loops beside it.
enum MermaidStateLayout {
    static func lay(
        out diagram: MermaidStateDiagram,
        metric: MarkdownTextMetric
    ) -> MermaidStateDrawing {
        var pass = MermaidStatePass(diagram: diagram, metric: metric)
        return pass.drawing()
    }

    /// The same layout with some simple states given a box of their own rather than one sized to
    /// their text, and other distances — the seam the class and ER diagrams lay out through
    /// (`MermaidBoxGraph`, §M39 ▸ Slice 14). A state diagram never passes either.
    static func lay(
        out diagram: MermaidStateDiagram,
        metric: MarkdownTextMetric,
        boxes: [Int: MermaidSize],
        spacing: MermaidLayered.Spacing
    ) -> MermaidStateDrawing {
        var pass = MermaidStatePass(diagram: diagram, metric: metric, boxes: boxes, spacing: spacing)
        return pass.drawing()
    }
}

/// Which region a state is drawn in: one of a composite's, or of the top level's when `owner` is
/// `nil`.
struct MermaidStateScope: Hashable {
    let owner: Int?
    let index: Int
}

/// A transition as a region ranks it: between the two states there that stand for its ends — the
/// ends themselves, or the composites they are inside.
struct MermaidStateLink {
    let transition: Int
    let from: Int
    let to: Int
}

/// Where a transition that crosses a border passes through a region it leaves or enters on its way
/// to the region it is ranked in (§M39 ▸ Slice 14): `member` is the state there that holds its end,
/// and the port sits in a channel along the region's edge. The region routes the line from the
/// member to the port between its boxes, where Slice 13 drew it straight from the state across
/// whatever lay between.
///
/// Which edge is the side the line really leaves by: the far one when the transition runs with the
/// flow where it is ranked and leaves from here (or runs against it and arrives here), the near one
/// otherwise. A back edge into a composite therefore comes in from below, rather than climbing the
/// whole composite to enter at its top.
struct MermaidStatePort {
    let transition: Int
    let member: Int
    let isExit: Bool
    /// In the channel after the members rather than before them.
    let isSink: Bool
}

/// A region, and the state there that holds a transition's end.
typealias MermaidStateLevel = (scope: MermaidStateScope, state: Int)

/// How a transition reaches the region it is ranked in: the states there that stand for its ends,
/// and the regions below that its source leaves and its target enters, innermost first.
struct MermaidStateRoute {
    let from: MermaidStateLevel
    let to: MermaidStateLevel
    let leaving: [MermaidStateLevel]
    let entering: [MermaidStateLevel]
}

/// One layout of one diagram, keeping what each region and composite worked out.
struct MermaidStatePass {
    let diagram: MermaidStateDiagram
    let metric: MarkdownTextMetric
    /// Each state's region.
    let scopeOf: [MermaidStateScope]
    /// Each transition laid out in a region, by region, as the two states there that stand for its
    /// ends.
    let linksIn: [MermaidStateScope: [MermaidStateLink]]
    /// Each state's loops: the transitions from it to itself, in the order written.
    let loopsOf: [Int: [Int]]
    /// Transitions between a composite and a state inside it, which no region can rank.
    let direct: [Int]
    /// Each region's ports, for the crossing transitions that leave or enter it.
    let portsIn: [MermaidStateScope: [MermaidStatePort]]
    /// Per crossing transition, the regions it leaves, innermost first, and the regions it enters,
    /// outermost first: the order its line passes through them.
    let exitScopes: [Int: [MermaidStateScope]]
    let entryScopes: [Int: [MermaidStateScope]]
    /// Simple states drawn at a size their caller chose, which only `MermaidBoxGraph` supplies.
    let boxes: [Int: MermaidSize]
    let spacing: MermaidLayered.Spacing

    var regionLayouts: [MermaidStateScope: MermaidStateRegionLayout] = [:]
    var compositeLayouts: [Int: MermaidStateBodyLayout] = [:]

    init(
        diagram: MermaidStateDiagram,
        metric: MarkdownTextMetric,
        boxes: [Int: MermaidSize] = [:],
        spacing: MermaidLayered.Spacing = Self.standardSpacing
    ) {
        self.diagram = diagram
        self.metric = metric
        self.boxes = boxes
        self.spacing = spacing
        var scopeOf = [MermaidStateScope](
            repeating: MermaidStateScope(owner: nil, index: 0),
            count: diagram.states.count
        )
        for (index, region) in diagram.regions.enumerated() {
            for state in region.states { scopeOf[state] = MermaidStateScope(owner: nil, index: index) }
        }
        for (owner, state) in diagram.states.enumerated() {
            for (index, region) in state.regions.enumerated() {
                for member in region.states {
                    scopeOf[member] = MermaidStateScope(owner: owner, index: index)
                }
            }
        }
        self.scopeOf = scopeOf

        var linksIn: [MermaidStateScope: [MermaidStateLink]] = [:]
        var loopsOf: [Int: [Int]] = [:]
        var direct: [Int] = []
        var portsIn: [MermaidStateScope: [MermaidStatePort]] = [:]
        var exitScopes: [Int: [MermaidStateScope]] = [:]
        var entryScopes: [Int: [MermaidStateScope]] = [:]
        var crossings: [(transition: Int, route: MermaidStateRoute)] = []
        for (position, transition) in diagram.transitions.enumerated() {
            if transition.from == transition.to {
                loopsOf[transition.from, default: []].append(position)
                continue
            }
            guard let scope = Self.common(transition.from, transition.to, scopeOf: scopeOf),
                  scope.from.state != scope.to.state
            else {
                direct.append(position)
                continue
            }
            linksIn[scope.from.scope, default: []].append(MermaidStateLink(
                transition: position,
                from: scope.from.state,
                to: scope.to.state
            ))
            guard !scope.leaving.isEmpty || !scope.entering.isEmpty else { continue }
            crossings.append((position, scope))
        }
        let forward = Self.forward(linksIn, diagram: diagram)
        for (position, route) in crossings {
            let withFlow = forward[route.from.scope]?.contains(position) ?? true
            for level in route.leaving {
                portsIn[level.scope, default: []].append(MermaidStatePort(
                    transition: position, member: level.state, isExit: true, isSink: withFlow
                ))
            }
            for level in route.entering {
                portsIn[level.scope, default: []].append(MermaidStatePort(
                    transition: position, member: level.state, isExit: false, isSink: !withFlow
                ))
            }
            exitScopes[position] = route.leaving.map(\.scope)
            entryScopes[position] = route.entering.reversed().map(\.scope)
        }
        self.linksIn = linksIn
        self.loopsOf = loopsOf
        self.direct = direct
        self.portsIn = portsIn
        self.exitScopes = exitScopes
        self.entryScopes = entryScopes
    }

    /// Per region, the transitions ranked there that run with its flow — from an earlier layer to a
    /// later one — once its cycles are broken. Only the layers are asked for, which do not depend on
    /// any size, so this can be known before the regions inside are laid out.
    private static func forward(
        _ linksIn: [MermaidStateScope: [MermaidStateLink]],
        diagram: MermaidStateDiagram
    ) -> [MermaidStateScope: Set<Int>] {
        // Indexed by the region's members in order, as `layRegion` indexes them, since the order
        // decides which edge of a cycle is the one broken.
        Dictionary(uniqueKeysWithValues: linksIn.map { scope, links in
            let region = scope.owner.map { diagram.states[$0].regions[scope.index] }
                ?? diagram.regions[scope.index]
            let local = Dictionary(
                region.states.enumerated().map { ($1, $0) }
            ) { first, _ in first }
            let ranking = MermaidLayering.rank(
                count: region.states.count,
                edges: links.map { link in
                    guard let from = local[link.from], let to = local[link.to] else { return nil }
                    return (from: from, to: to)
                }
            )
            return (scope, Set(links.filter { link in
                guard let from = local[link.from], let to = local[link.to] else { return true }
                return ranking.layerOf[from] < ranking.layerOf[to]
            }.map(\.transition)))
        })
    }

    /// The innermost region holding both states, as the state in it that holds each — the state
    /// itself, or the composite it is inside — and the regions below it each end is in, innermost
    /// first, as the state there that holds it.
    private static func common(
        _ from: Int,
        _ to: Int,
        scopeOf: [MermaidStateScope]
    ) -> MermaidStateRoute? {
        func chain(_ state: Int) -> [MermaidStateLevel] {
            var result: [MermaidStateLevel] = []
            var current = state
            while result.count <= scopeOf.count {
                let scope = scopeOf[current]
                result.append((scope, current))
                guard let owner = scope.owner else { break }
                current = owner
            }
            return result
        }
        let fromChain = chain(from)
        let toChain = chain(to)
        for (depth, link) in fromChain.enumerated() {
            if let match = toChain.firstIndex(where: { $0.scope == link.scope }) {
                return MermaidStateRoute(
                    from: link,
                    to: toChain[match],
                    leaving: Array(fromChain[..<depth]),
                    entering: Array(toChain[..<match])
                )
            }
        }
        return nil
    }

    // MARK: - The drawing

    /// Lays every region out from the inside, then walks them from the top level down to put each
    /// one where its composite landed, and only then draws transitions, since a transition that
    /// crosses a border needs a frame from deeper down than the region it is ranked in.
    mutating func drawing() -> MermaidStateDrawing {
        let rootScopes = diagram.regions.indices.map { MermaidStateScope(owner: nil, index: $0) }
        let body = layBody(rootScopes, direction: diagram.direction, title: nil)
        var frames = [MermaidRect](
            repeating: MermaidRect(x: 0, y: 0, width: 0, height: 0),
            count: diagram.states.count
        )
        var placed: [(scope: MermaidStateScope, origin: MermaidPoint)] = []
        var notes: [MermaidStateDrawing.Note] = []
        var dividers = body.dividers
        var queue = Array(zip(rootScopes, body.origins))
        var head = 0
        while head < queue.count {
            let (scope, origin) = queue[head]
            head += 1
            guard let layout = regionLayouts[scope] else { continue }
            placed.append((scope, origin))
            for (position, state) in layout.members.enumerated() {
                let frame = layout.frames[position].offset(by: origin)
                frames[state] = frame
                notes += zip(diagram.states[state].notes, layout.notes[position]).map {
                    note($0, frame: $1.offset(by: origin), of: frame)
                }
                guard let inside = compositeLayouts[state] else { continue }
                let corner = MermaidPoint(x: frame.x, y: frame.y)
                dividers += inside.dividers.map { $0.map { $0.offset(by: corner) } }
                for (index, regionOrigin) in inside.origins.enumerated() {
                    queue.append((
                        MermaidStateScope(owner: state, index: index),
                        regionOrigin.offset(by: corner)
                    ))
                }
            }
        }
        let origins = Dictionary(placed.map { ($0.scope, $0.origin) }) { first, _ in first }
        let ranked = placed.flatMap { scope, origin in
            (regionLayouts[scope]?.links ?? []).map {
                edge($0, origin: origin, origins: origins, frames: frames)
            }
        }
        return MermaidStateDrawing(
            width: body.size.width,
            height: body.size.height,
            nodes: diagram.states.indices.map { node($0, frame: frames[$0]) },
            notes: notes,
            edges: ranked + loops(frames) + directEdges(frames),
            dividers: dividers
        )
    }
}

extension MermaidRect {
    func offset(by origin: MermaidPoint) -> MermaidRect {
        MermaidRect(x: x + origin.x, y: y + origin.y, width: width, height: height)
    }
}

extension MermaidPoint {
    func offset(by origin: MermaidPoint) -> MermaidPoint {
        MermaidPoint(x: x + origin.x, y: y + origin.y)
    }
}
