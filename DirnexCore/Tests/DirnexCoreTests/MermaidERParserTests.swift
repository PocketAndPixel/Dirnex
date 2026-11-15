import Foundation
import Testing

@testable import DirnexCore

/// Reading an ER diagram (PLAN.md §M39 ▸ Slice 14), against what Mermaid 12.3 drew on its own
/// documentation page and the shape of the one ER diagram the corpus found (a Figma skill's
/// reference, written out here in other words).
@Suite("Mermaid ER diagram parser")
struct MermaidERParserTests {
    private func parse(_ body: String) -> MermaidERDiagram {
        guard case let .entityRelationship(diagram) = MermaidParser.parse("erDiagram\n" + body) else {
            Issue.record("not an ER diagram")
            return MermaidERDiagram(
                direction: .topDown,
                entities: [],
                groups: [],
                relationships: [],
                undrawn: []
            )
        }
        return diagram
    }

    @Test("every cardinality, in either character order, at either end")
    func symbols() {
        let cases: [(String, [MermaidERDiagram.Cardinality])] = [
            ("A |o--o| B : x", [.zeroOrOne, .zeroOrOne]),
            ("A ||--|| B : x", [.exactlyOne, .exactlyOne]),
            ("A }o--o{ B : x", [.zeroOrMore, .zeroOrMore]),
            ("A }|--|{ B : x", [.oneOrMore, .oneOrMore]),
            ("A o{--|| B : x", [.zeroOrMore, .exactlyOne]),
            ("A o|--|o B : x", [.zeroOrOne, .zeroOrOne]),
            ("A |{--}| B : x", [.oneOrMore, .oneOrMore])
        ]
        for (line, ends) in cases {
            let relationship = parse(line).relationships.first
            #expect(relationship.map { [$0.fromCardinality, $0.toCardinality] } == ends, "\(line)")
        }
    }

    @Test("two dots do not identify and two dashes do, and so do their words")
    func identification() {
        let diagram = parse("""
        CAR ||--o{ NAMED-DRIVER : allows
        PERSON }o..o{ NAMED-DRIVER : is
        CAR 1 to zero or more NAMED-DRIVER : allows
        PERSON many(0) optionally to 0+ NAMED-DRIVER : is
        MANUFACTURER only one to one or many CAR : makes
        A 1+ to 1 B : x
        """)
        #expect(diagram.relationships.map(\.isIdentifying) == [true, false, true, false, true, true])
        #expect(diagram.relationships.map(\.fromCardinality) == [
            .exactlyOne, .zeroOrMore, .exactlyOne, .zeroOrMore, .exactlyOne, .oneOrMore
        ])
        #expect(diagram.relationships.map(\.toCardinality) == [
            .zeroOrMore, .zeroOrMore, .zeroOrMore, .zeroOrMore, .oneOrMore, .exactlyOne
        ])
        #expect(
            diagram.entities.map(\.id) == ["CAR", "NAMED-DRIVER", "PERSON", "MANUFACTURER", "A", "B"]
        )
    }

    @Test("a label loses its quotes, and the first entity is the source")
    func labels() {
        let diagram = parse("PRODUCT ||--o{ LINE_ITEM : \"appears in\"\nA ||--|| B : \"\"")
        #expect(diagram.relationships.map(\.label) == ["appears in", nil])
        #expect(diagram.relationships.first?.from == .entity(0))
        #expect(diagram.relationships.first?.to == .entity(1))
    }

    @Test("an attribute is a type, a name, any keys and a quoted comment")
    func attributes() {
        let diagram = parse("""
        PERSON {
            string driversLicense PK "The license #"
            string(99) firstName "Only 99 characters"
            string[] parts
            string? middle
            int *id
            string customerId PK, FK
            string avatarUrl "Gravatar URL"
        }
        """)
        let attributes = diagram.entity("PERSON")?.attributes ?? []
        #expect(
            attributes.map(\.type) == [
                "string",
                "string(99)",
                "string[]",
                "string?",
                "int",
                "string",
                "string"
            ]
        )
        #expect(attributes.map(\.name) == [
            "driversLicense", "firstName", "parts", "middle", "*id", "customerId", "avatarUrl"
        ])
        #expect(attributes.map(\.keys) == ["PK", nil, nil, nil, nil, "PK,FK", nil])
        #expect(attributes.map(\.comment) == [
            "The license #", "Only 99 characters", nil, nil, nil, nil, "Gravatar URL"
        ])
    }

    @Test("an alias names the box, a quoted name may hold spaces, and a style suffix is dropped")
    func names() {
        let diagram = parse("""
        p[Person] {
            string firstName
        }
        a["Customer Account"] {
            string email
        }
        p ||--o| a : has
        "This ❤ Unicode"
        CAR:::someclass { }
        PERSON:::foo ||--|| CAR : owns
        """)
        #expect(diagram.entities.map(\.id) == ["p", "a", "This ❤ Unicode", "CAR", "PERSON"])
        #expect(
            diagram.entities.map(\.label) == [
                "Person",
                "Customer Account",
                "This ❤ Unicode",
                "CAR",
                "PERSON"
            ]
        )
        #expect(diagram.relationships.count == 2)
    }

    @Test("an entity belongs to the first subgraph that mentions it")
    func subgraphMembership() {
        let diagram = parse("""
        A ||--|| B : x
        subgraph S
            A
        end
        subgraph T
            B
            C
        end
        subgraph U
            B
        end
        subgraph V
            D ||--|| E : y
        end
        E ||--|| F : z
        """)
        func home(_ id: String) -> String? {
            diagram.entity(id)?.group.map { diagram.groups[$0].id }
        }
        #expect(home("A") == "S")
        #expect(home("B") == "T")
        #expect(home("C") == "T")
        #expect(home("D") == "V")
        #expect(home("E") == "V")
        #expect(home("F") == nil)
        #expect(diagram.groups.map(\.id) == ["S", "T", "U", "V"])
    }

    @Test("a subgraph's id and title, its nesting, its direction, and a relationship to it")
    func subgraphs() {
        let diagram = parse("""
        direction LR
        subgraph TOP
            direction TB
            subgraph "Customer Domain"
                CUSTOMER
            end
            subgraph id1 [title 1]
                ORDER
            end
        end
        TOP ||--|| B : links
        "Customer Domain" ||--o{ ORDER : contains
        """)
        #expect(diagram.direction == .leftRight)
        #expect(diagram.groups.map(\.id) == ["TOP", "Customer Domain", "id1"])
        #expect(diagram.groups.map(\.title) == ["TOP", "Customer Domain", "title 1"])
        #expect(diagram.groups.map(\.parent) == [nil, 0, 0])
        #expect(diagram.groups.map(\.direction) == [.topDown, nil, nil])
        #expect(diagram.relationships.map(\.from) == [.group(0), .group(1)])
        #expect(diagram.relationships.map(\.to) == [.entity(2), .entity(1)])
    }

    @Test("styling is named as undrawn")
    func undrawn() {
        let diagram = parse("""
        id1 ||--|| id2 : label
        style id1 fill:#f9f
        classDef foo stroke:#f00
        class id1 foo
        """)
        #expect(diagram.undrawn == ["class", "classDef", "style"])
        #expect(diagram.entities.map(\.id) == ["id1", "id2"])
    }

    @Test("the corpus's shape: relationships first, then each entity's table")
    func corpusShape() {
        let diagram = parse("""
            ACCOUNT ||--|| SETTINGS : has
            ACCOUNT ||--o{ INVOICE : receives
            INVOICE }|..|{ COUPON : discounted_by

            ACCOUNT {
                string id PK
                string email UK
            }
            SETTINGS {
                string accountId PK, FK
                string theme "light | dark"
            }
            COUPON["Coupon Code"] {
                string code PK
            }
        """)
        #expect(diagram.entities.map(\.id) == ["ACCOUNT", "SETTINGS", "INVOICE", "COUPON"])
        #expect(diagram.entity("COUPON")?.label == "Coupon Code")
        #expect(diagram.entity("SETTINGS")?.attributes.last?.comment == "light | dark")
        #expect(diagram.relationships.map(\.isIdentifying) == [true, true, false])
    }
}
