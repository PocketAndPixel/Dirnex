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

    var regionLayouts: [MermaidStateScope: MermaidStateRegionLayout] = [:]
    var compositeLayouts: [Int: MermaidStateBodyLayout] = [:]

    init(diagram: MermaidStateDiagram, metric: MarkdownTextMetric) {
        self.diagram = diagram
        self.metric = metric
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
        for (position, transition) in diagram.transitions.enumerated() {
            if transition.from == transition.to {
                loopsOf[transition.from, default: []].append(position)
                continue
            }
            let scope = Self.common(transition.from, transition.to, scopeOf: scopeOf)
            if let scope, scope.from.state != scope.to.state {
                linksIn[scope.from.scope, default: []].append(MermaidStateLink(
                    transition: position,
                    from: scope.from.state,
                    to: scope.to.state
                ))
            } else {
                direct.append(position)
            }
        }
        self.linksIn = linksIn
        self.loopsOf = loopsOf
        self.direct = direct
    }

    /// The innermost region holding both states, as the state in it that holds each — the state
    /// itself, or the composite it is inside.
    private static func common(
        _ from: Int,
        _ to: Int,
        scopeOf: [MermaidStateScope]
    ) -> (from: (scope: MermaidStateScope, state: Int), to: (scope: MermaidStateScope, state: Int))? {
        func chain(_ state: Int) -> [(scope: MermaidStateScope, state: Int)] {
            var result: [(scope: MermaidStateScope, state: Int)] = []
            var current = state
            while result.count <= scopeOf.count {
                let scope = scopeOf[current]
                result.append((scope, current))
                guard let owner = scope.owner else { break }
                current = owner
            }
            return result
        }
        let toChain = chain(to)
        for link in chain(from) {
            if let match = toChain.first(where: { $0.scope == link.scope }) {
                return (link, match)
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
        let ranked = placed.flatMap { scope, origin in
            (regionLayouts[scope]?.links ?? []).map { edge($0, origin: origin, frames: frames) }
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
