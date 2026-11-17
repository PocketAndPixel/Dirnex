import Foundation

/// A class diagram: `classDiagram` (PLAN.md §M39 ▸ Slice 14).
///
/// Read off Mermaid 12.3 drawing on its own documentation page, in its classic look, since its docs
/// state few of the rules:
///
/// - **The first class a relation names is drawn above the second**, whatever the arrow says:
///   `A <|-- B` puts `A` on top with the triangle at its end, and `C --|> D` puts `C` on top.
/// - **A class is three compartments**, its name, its attributes and its methods, and an empty one
///   is still drawn: a class with no members is its name over two empty bands.
/// - **A member is a method when it holds a `)`**, wherever the line was written, so the methods are
///   drawn under the attributes even when the file interleaves them. `$` at the end underlines a
///   member and `*` italicizes it.
/// - **`~T~` is a generic**, paired from the outside in: `List~List~int~~` is `List<List<int>>`.
/// - **Each lollipop is its own interface**: `A --() bar` twice draws two `bar`s.
/// - **A note for a class is a box above it** on a dotted line; a note for nothing floats.
/// - **A namespace is a titled box**, and a dotted name nests: `Company.Engineering` is
///   `Engineering` inside `Company`. Only a `class` statement inside one puts a class in it.
/// - **Entities are decoded**: the NuGet README the corpus found writes `Task&lt;int&gt;`, and
///   Mermaid draws `Task<int>`.
struct MermaidClassDiagram: Equatable {
    enum Kind: Equatable {
        case `class`
        /// A lollipop's interface: its name, with no box, at the circle end of its line.
        case interface
        case note
    }

    struct Member: Equatable {
        /// What is drawn: visibility, name, generics resolved, and a method's `(…) : type`.
        let text: String
        /// `$`, underlined.
        let isStatic: Bool
        /// `*`, in italics.
        let isAbstract: Bool
    }

    struct Node: Equatable {
        let id: String
        let kind: Kind
        /// A class's name as drawn (generics resolved, or its `["label"]`), or an interface's.
        let label: String
        /// `<<interface>>` and the like, without the brackets.
        let annotations: [String]
        let attributes: [Member]
        let methods: [Member]
        /// A note's lines.
        let lines: [String]
        /// The namespace it is drawn in, by index.
        let namespace: Int?
    }

    struct Namespace: Equatable {
        /// The full dotted id, `Company.Engineering`.
        let id: String
        /// What its box says: the last part of a dotted id, or its `["title"]`.
        let title: String
        let parent: Int?
        /// How many nodes had been mentioned when it was, which places it among them in the
        /// first-mention order the layout breaks ties by.
        let position: Int
    }

    /// How one end of a relation is drawn.
    enum End: Equatable {
        case none
        /// `<|` or `|>`: a hollow triangle, inheritance or (dotted) realization.
        case `extension`
        /// `*`: a filled diamond.
        case composition
        /// `o`: a hollow diamond.
        case aggregation
        /// `<` or `>`: an arrowhead, association or (dotted) dependency.
        case arrow
        /// `()`: a lollipop's circle.
        case lollipop
    }

    struct Relation: Equatable {
        /// Indices into `nodes`. `from` is the one written first, drawn above.
        let from: Int
        let to: Int
        let fromEnd: End
        let toEnd: End
        /// `..` rather than `--`.
        let isDashed: Bool
        let label: String?
        /// `"1"` written beside the first class, and beside the second.
        let fromCardinality: String?
        let toCardinality: String?
        /// A note's dotted line to its class.
        var isNoteLink = false
    }

    let direction: MermaidFlowchart.Direction
    let nodes: [Node]
    let namespaces: [Namespace]
    let relations: [Relation]
    /// Constructs this subset does not draw — `click`, `link`, `callback`, `style`, `classDef`,
    /// `cssClass` — named as the other diagrams' are (`MermaidFlowchart.undrawn`).
    let undrawn: [String]

    /// The node with this id, for a test or a caller that knows the file's own names.
    func node(_ id: String) -> Node? {
        nodes.first { $0.id == id }
    }
}
