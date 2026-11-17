import Foundation

/// A state diagram: `stateDiagram` or `stateDiagram-v2` (PLAN.md §M39 ▸ Slice 13).
///
/// The rules below were read off Mermaid itself, rendering on its own documentation page, because
/// its docs state few of them:
///
/// - **One start and one end per region.** Every `[*] -->` in a region shares one start dot, every
///   `--> [*]` one end, and a composite state's inside, or each of its `--` regions, has its own.
/// - **A description replaces the name, and a second one makes a titled box**: `s1 : first` then
///   `s1 : second` draws "first" over a rule with "second" under it.
/// - **A state belongs to the last composite block that mentions it**, and a mention at the top
///   level never moves it out: `x --> inner1` before `state Outer { inner1 }` still puts `inner1`
///   inside `Outer`, with the transition crossing its border.
/// - **A composite's inside runs top to bottom** unless its own block says `direction`, whatever
///   the diagram's direction.
///
/// States are held flat, in **first-mention order**, which breaks every tie the layout has to break
/// (the flowchart's reason, `MermaidFlowchart`), and a region lists its members by index.
struct MermaidStateDiagram: Equatable {
    enum Kind: Equatable {
        case state
        /// `<<choice>>`, drawn as a small diamond with no text.
        case choice
        /// `<<fork>>` and `<<join>>`: one bar across the flow, drawn the same.
        case fork
        case join
        /// `[*]` as a transition's source.
        case start
        /// `[*]` as a transition's target.
        case end
    }

    /// Which side of its state a note sits on — of the page, whatever the flow.
    enum NoteSide: Equatable {
        case left
        case right
    }

    struct Note: Equatable {
        let side: NoteSide
        /// One string per line, as the note was written.
        let lines: [String]
    }

    /// A part of a composite (or of the whole diagram) laid out on its own: everything inside a
    /// `state X { … }`, or each piece of it a `--` line separates.
    struct Region: Equatable {
        /// Indices into `MermaidStateDiagram.states`, in first-mention order.
        let states: [Int]
    }

    struct State: Equatable {
        let id: String
        let kind: Kind
        /// Its `id : text` lines and `state "text" as id`, in the order written. The first is what
        /// the state is called; any more are drawn under a rule beneath it.
        let descriptions: [String]
        /// A composite state's inside. Empty for a simple state.
        let regions: [Region]
        /// A composite's own `direction`, when its block wrote one. Mermaid's default for an
        /// inside is top to bottom, not the diagram's direction (`insideDirection`).
        let direction: MermaidFlowchart.Direction?
        let notes: [Note]

        var isComposite: Bool { !regions.isEmpty }
        /// What the box says first: its first description, else its id.
        var title: String { descriptions.first ?? id }
        var insideDirection: MermaidFlowchart.Direction { direction ?? .topDown }
    }

    struct Transition: Equatable {
        /// Indices into `states`.
        let from: Int
        let to: Int
        let label: String?
    }

    let direction: MermaidFlowchart.Direction
    let states: [State]
    /// The top level's regions — one, unless the file split the top level with `--` too.
    let regions: [Region]
    let transitions: [Transition]
    /// Constructs this subset does not draw — `classDef`, `class`, `style`, a floating note — named
    /// as the flowchart's are (`MermaidFlowchart.undrawn`).
    let undrawn: [String]

    /// The state with this id, for a test or a caller that knows the file's own names.
    func state(_ id: String) -> State? {
        states.first { $0.id == id }
    }
}
