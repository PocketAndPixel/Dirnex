import Foundation

/// An entity-relationship diagram: `erDiagram` (PLAN.md §M39 ▸ Slice 14).
///
/// Read off Mermaid 12.3 drawing on its own documentation page, in the classic look its front
/// matter can still ask for (ER diagrams default to ELK and a newer look there, which GitHub's older
/// Mermaid does not draw):
///
/// - **The first entity a relationship names is drawn above the second.**
/// - **Each end is a crow's foot pair**: the mark that touches the entity is the maximum (a bar for
///   one, a foot for many), the one further out the minimum (a ring for zero, a bar for one). Either
///   order of the two characters is read, so `o{` and `}o` are one cardinality, and so are the word
///   forms (`zero or more`, `many(0)`, `0+`).
/// - **`--` and `to` identify, `..` and `optionally to` do not**, and the latter is dashed.
/// - **An entity is a table** of type, name, keys and comment, the last two columns drawn only when
///   some attribute has one; an entity with no attributes is its name in a box.
/// - **A subgraph is a titled box** (Mermaid 11.17), nests, may say its own `direction`, and may be
///   one end of a relationship by its id.
struct MermaidERDiagram: Equatable {
    enum Cardinality: Equatable {
        case zeroOrOne
        case exactlyOne
        case zeroOrMore
        case oneOrMore
    }

    struct Attribute: Equatable {
        let type: String
        let name: String
        /// `PK`, `FK`, `UK`, as written, joined by commas.
        let keys: String?
        let comment: String?
    }

    struct Entity: Equatable {
        let id: String
        /// Its `[alias]`, else its id.
        let label: String
        let attributes: [Attribute]
        /// The subgraph it is drawn in, by index.
        let group: Int?
    }

    struct Group: Equatable {
        let id: String
        let title: String
        let parent: Int?
        let direction: MermaidFlowchart.Direction?
        /// How many entities had been mentioned when it opened (`MermaidClassDiagram.Namespace`).
        let position: Int
    }

    /// One end of a relationship: an entity, or a subgraph by its id.
    enum Endpoint: Equatable {
        case entity(Int)
        case group(Int)
    }

    struct Relationship: Equatable {
        /// Drawn above `to`.
        let from: Endpoint
        let to: Endpoint
        let fromCardinality: Cardinality
        let toCardinality: Cardinality
        /// `--` or `to`: a solid line. `..` or `optionally to` is dashed.
        let isIdentifying: Bool
        let label: String?
    }

    let direction: MermaidFlowchart.Direction
    let entities: [Entity]
    let groups: [Group]
    let relationships: [Relationship]
    /// `style`, `classDef` and `class`, named as the other diagrams' are.
    let undrawn: [String]

    func entity(_ id: String) -> Entity? {
        entities.first { $0.id == id }
    }
}
