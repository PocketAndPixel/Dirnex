import Foundation

/// What a ```` ```mermaid ```` fence turned out to hold (PLAN.md §M18 ▸ Slice 4).
///
/// The subset is **flowchart and sequence**, and this enum is where that boundary is stated. It is
/// deliberately a closed set with a named escape: every other diagram type lands in `.unsupported`
/// carrying the word the file actually wrote, so a fence the renderer cannot draw shows its source
/// *and says which type it was*. Silently rendering the source of a diagram somebody expected drawn
/// is the failure this milestone set out to avoid, and it is the one a subset makes likely.
///
/// Hand-rolled over vendoring `mermaid.min.js`, decided with the user at open: bundling would have
/// bought every type at the price of a ~3 MB third-party asset, a JS engine running on every cursor
/// step, and output §2 cannot test — the three costs that got Highlightr and tree-sitter rejected at
/// M17, arriving in a different shape.
enum MermaidDiagram: Equatable {
    case flowchart(MermaidFlowchart)
    case sequence(MermaidSequence)
    /// A type this subset does not draw, named as the file spelled it (`stateDiagram-v2`).
    case unsupported(String)
}

/// A flowchart: `graph`/`flowchart` with a direction, shaped nodes and labelled edges.
///
/// Nodes are held **in declaration order** rather than in a dictionary, because that order is what
/// breaks every tie the layout has to break — which layer a node lands in when several are equally
/// deep, and where it sits inside that layer before the barycenter pass moves it. A dictionary would
/// make the drawing depend on hash order, i.e. differ between runs of the same file.
struct MermaidFlowchart: Equatable {
    /// The reading direction. `TB` is a spelling of `TD`, not a fifth direction.
    enum Direction: String, Equatable {
        case topDown = "TD"
        case leftRight = "LR"
        case rightLeft = "RL"
        case bottomUp = "BT"

        /// Whether ranks advance across the page rather than down it, which is the only thing the
        /// layout needs to ask — the two reversed directions differ from their twins by a flip at
        /// the end, not by a different algorithm.
        var isHorizontal: Bool { self == .leftRight || self == .rightLeft }
        var isReversed: Bool { self == .rightLeft || self == .bottomUp }

        static func named(_ text: String) -> Direction? {
            text.uppercased() == "TB" ? .topDown : Direction(rawValue: text.uppercased())
        }
    }

    /// A node's outline. The set mermaid's own bracket forms name, and no more: an unrecognized
    /// bracket pair leaves the node a rectangle carrying the text between the brackets, which is
    /// the same "an unreadable construct falls back to its literal text" rule the whole renderer
    /// keeps.
    enum Shape: String, Equatable {
        case rectangle
        case rounded
        case circle
        case diamond
        case subroutine
    }

    struct Node: Equatable {
        let id: String
        /// What is drawn. Defaults to the id, which is what mermaid does for a bare `A --> B`.
        let label: String
        let shape: Shape
    }

    /// A line's stroke. Not a colour — the emitter writes class names and `currentColor` only, so
    /// the app's stylesheet colours a diagram in both appearances the way it colours everything else.
    enum Stroke: String, Equatable {
        case solid
        case dotted
        case thick
    }

    /// What an edge ends in. An enum rather than the two booleans it started as, because the
    /// vocabulary is genuinely three-valued — mermaid's `--x` and `--o` are a cross and a circle,
    /// and modelling them as "an arrow, sort of" would draw the wrong picture rather than none.
    enum Tip: String, Equatable {
        case none
        case arrow
        case cross
        case circle
    }

    struct Edge: Equatable {
        let from: String
        let to: String
        let label: String?
        let stroke: Stroke
        /// The tail's tip (`<-->`, `x--x`), which mermaid allows independently of the head's.
        let tail: Tip
        let head: Tip
    }

    let direction: Direction
    let nodes: [Node]
    let edges: [Edge]
    /// Constructs found inside the diagram that this subset does not draw — `subgraph`, `style`,
    /// `click`. Recorded rather than merely skipped, because the alternative is a picture that is
    /// *quietly* missing something its author put there. The diagram still draws; the page says
    /// what it left out, in the app's words rather than the core's (`MarkdownRenderOptions`).
    let undrawn: [String]
}

/// A sequence diagram: participants across the top, time down the page.
///
/// Positional, so it needs no layout beyond column and row arithmetic — which is why it shares the
/// milestone's slice with the flowchart rather than costing one of its own.
struct MermaidSequence: Equatable {
    struct Participant: Equatable {
        let id: String
        /// The alias, when the file wrote `participant A as Alice`; the id otherwise.
        let label: String
        /// `actor A` rather than `participant A` — drawn as a stick figure.
        let isActor: Bool
    }

    /// A message's line and head. The four arrows the subset names, plus the crossed head.
    enum MessageStyle: Equatable {
        /// `->>` — solid line, filled head. The common one.
        case solidArrow
        /// `-->>` — dashed line, filled head. A reply.
        case dashedArrow
        /// `->` — solid line, open head.
        case solidOpen
        /// `-->` — dashed line, open head.
        case dashedOpen
        /// `--x` / `-x` — a cross instead of a head.
        case crossed(isDashed: Bool)

        var isDashed: Bool {
            switch self {
            case .dashedArrow, .dashedOpen: true
            case let .crossed(isDashed): isDashed
            case .solidArrow, .solidOpen: false
            }
        }
    }

    /// Where a note sits relative to the participants it names.
    enum NotePlacement: String, Equatable {
        case over
        case leftOf
        case rightOf
    }

    enum Event: Equatable {
        case message(from: String, to: String, text: String, style: MessageStyle)
        case note(placement: NotePlacement, participants: [String], text: String)
        /// `activate A`, or the `+` suffix on a message's arrow.
        case activate(String)
        case deactivate(String)
    }

    /// In first-appearance order, which is the order they are drawn across the top — a participant
    /// declared explicitly keeps its place, and one that only ever appears in a message is appended
    /// where it was first mentioned.
    let participants: [Participant]
    let events: [Event]
    /// The grouping constructs this subset does not draw — `loop`, `alt`, `opt`, `par`. Same reason
    /// as the flowchart's: a skipped `alt` leaves two branches drawn one after the other, which is a
    /// picture that reads as sequential and is not.
    let undrawn: [String]
}
