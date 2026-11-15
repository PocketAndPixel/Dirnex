import Foundation
import Testing

@testable import DirnexCore

/// Reading a class diagram (PLAN.md §M39 ▸ Slice 14).
///
/// Every rule below was read off Mermaid 12.3 drawing on its own documentation page; the shape of
/// the corpus case — namespaces, `{ <<enum>>` on the brace line, members written with `&lt;` —
/// is the NuGet README the corpus found, written out here in other words.
@Suite("Mermaid class diagram parser")
struct MermaidClassParserTests {
    private func parse(_ body: String) -> MermaidClassDiagram {
        guard case let .classDiagram(diagram) = MermaidParser.parse("classDiagram\n" + body) else {
            Issue.record("not a class diagram")
            return MermaidClassDiagram(
                direction: .topDown,
                nodes: [],
                namespaces: [],
                relations: [],
                undrawn: []
            )
        }
        return diagram
    }

    private func relation(_ line: String) -> MermaidClassDiagram.Relation? {
        parse(line).relations.first
    }

    // MARK: - Relations

    /// One case of `markers`: a relation and how its two ends and its line are drawn.
    private struct Ends {
        let line: String
        let from: MermaidClassDiagram.End
        let to: MermaidClassDiagram.End
        let isDashed: Bool

        init(
            _ line: String,
            _ from: MermaidClassDiagram.End,
            _ to: MermaidClassDiagram.End,
            _ isDashed: Bool
        ) {
            self.line = line
            self.from = from
            self.to = to
            self.isDashed = isDashed
        }
    }

    @Test("each end's marker is what touches the line on that side")
    func markers() {
        let cases = [
            Ends("A <|-- B", .extension, .none, false),
            Ends("A --|> B", .none, .extension, false),
            Ends("A *-- B", .composition, .none, false),
            Ends("A --* B", .none, .composition, false),
            Ends("A o-- B", .aggregation, .none, false),
            Ends("A --o B", .none, .aggregation, false),
            Ends("A <-- B", .arrow, .none, false),
            Ends("A --> B", .none, .arrow, false),
            Ends("A -- B", .none, .none, false),
            Ends("A .. B", .none, .none, true),
            Ends("A ..|> B", .none, .extension, true),
            Ends("A ..> B", .none, .arrow, true),
            Ends("A <|--|> B", .extension, .extension, false),
            Ends("A *--o B", .composition, .aggregation, false)
        ]
        for ends in cases {
            let (line, from, to, dashed) = (ends.line, ends.from, ends.to, ends.isDashed)
            let parsed = relation(line)
            #expect(parsed?.fromEnd == from, "\(line)")
            #expect(parsed?.toEnd == to, "\(line)")
            #expect(parsed?.isDashed == dashed, "\(line)")
        }
    }

    @Test("the class written first is the relation's source, whatever the arrow says")
    func firstWrittenIsSource() {
        let diagram = parse("A <|-- B\nC --|> D")
        #expect(diagram.nodes.map(\.id) == ["A", "B", "C", "D"])
        #expect(diagram.relations.map(\.from) == [0, 2])
        #expect(diagram.relations.map(\.to) == [1, 3])
    }

    @Test("an o counts as aggregation only standing alone")
    func aggregationNeedsSpace() {
        let plain = relation("foo--bar")
        #expect(plain?.fromEnd == MermaidClassDiagram.End.none)
        #expect(parse("foo--bar").nodes.map(\.id) == ["foo", "bar"])
        let both = relation("foo --o bar")
        #expect(both?.toEnd == .aggregation)
        #expect(parse("foo --o bar").nodes.map(\.id) == ["foo", "bar"])
    }

    @Test("cardinalities are the quoted strings beside the line, and their dots are not one")
    func cardinalities() {
        let parsed = relation("Student \"1\" --> \"0..*\" Course : takes")
        #expect(parsed?.fromCardinality == "1")
        #expect(parsed?.toCardinality == "0..*")
        #expect(parsed?.isDashed == false)
        #expect(parsed?.label == "takes")
        #expect(
            parse("Galaxy --> \"many\" Star : Contains").relations.first?.toCardinality == "many"
        )
        // A `..` inside the first cardinality comes before the line, and is not one.
        let optional = relation("Student \"0..1\" --o \"1..*\" Course")
        #expect(optional?.fromCardinality == "0..1")
        #expect(optional?.toCardinality == "1..*")
        #expect(optional?.toEnd == .aggregation)
        #expect(optional?.isDashed == false)
    }

    @Test("a label is everything after the colon, its quotes kept as Mermaid keeps them")
    func labels() {
        #expect(relation("A --> B : \"quoted label\"")?.label == "\"quoted label\"")
        #expect(relation("A --> B : has a: colon")?.label == "has a: colon")
        #expect(relation("A --> B")?.label == nil)
        #expect(relation("A --> B : Task&lt;int&gt;")?.label == "Task<int>")
    }

    @Test("each lollipop is an interface of its own, at the circle's end")
    func lollipops() {
        let diagram = parse("Class01 --() bar\nClass02 --() bar\nfoo ()-- Class01")
        let interfaces = diagram.nodes.filter { $0.kind == .interface }
        #expect(interfaces.map(\.label) == ["bar", "bar", "foo"])
        #expect(diagram.nodes.filter { $0.kind == .class }.map(\.id) == ["Class01", "Class02"])
        let last = diagram.relations[2]
        #expect(diagram.nodes[last.from].kind == .interface)
        #expect(last.fromEnd == .lollipop)
        #expect(diagram.nodes[last.to].id == "Class01")
    }

    // MARK: - Members

    @Test("a member is a method when it holds a closing parenthesis after its first character")
    func methodsAndAttributes() {
        let diagram = parse("""
        class A {
            +int x
            +run()
            -String name
            go(int a) bool
        }
        A : +int y
        A : +stop()
        """)
        let node = diagram.node("A")
        #expect(node?.attributes.map(\.text) == ["+int x", "-String name", "+int y"])
        #expect(node?.methods.map(\.text) == ["+run()", "go(int a) : bool", "+stop()"])
    }

    @Test("$ underlines and * italicizes, after the parenthesis or at the end")
    func classifiers() {
        let node = parse("""
        class A {
            +int id$
            #draw(int x, int y)* bool
            ~area()$ double
            +shape() Shape*
            plain
        }
        """).node("A")
        let members = (node?.attributes ?? []) + (node?.methods ?? [])
        #expect(members.map(\.text) == [
            "+int id", "plain", "#draw(int x, int y) : bool", "~area() : double", "+shape() : Shape"
        ])
        #expect(members.map(\.isStatic) == [true, false, false, true, false])
        #expect(members.map(\.isAbstract) == [false, false, true, false, true])
    }

    @Test("generics pair from the outside in, and a comma inside one is kept")
    func generics() {
        #expect(MermaidClassParser.generics("List~List~int~~") == "List<List<int>>")
        #expect(MermaidClassParser.generics("Map~K, V~") == "Map<K, V>")
        #expect(MermaidClassParser.generics("List~int~ a, Map~K,V~ b") == "List<int> a, Map<K,V> b")
        #expect(MermaidClassParser.generics("~single") == "~single")
        let diagram = parse("class Square~Shape~\nSquare --> Map~K, V~")
        #expect(diagram.node("Square")?.label == "Square<Shape>")
        #expect(diagram.node("Map")?.label == "Map<K, V>")
    }

    @Test("references are decoded where Mermaid decodes them, and classified as written")
    func entities() {
        let node = parse("""
        class C {
        &lt;&lt;rw&gt;&gt; +string Id
        +Task&lt;int&gt; Get()
        &lt;&lt;enum&gt;&gt;
        }
        """).node("C")
        // `&lt;&lt;enum&gt;&gt;` is no annotation, since Mermaid tests for `<<` before it decodes.
        #expect(node?.annotations == [])
        #expect(node?.attributes.map(\.text) == ["<<rw>> +string Id", "<<enum>>"])
        #expect(node?.methods.map(\.text) == ["+Task<int> Get()"])
        #expect(MermaidText.decoded("&amp;lt; &#65;&#x42; &unknown; &") == "&lt; AB &unknown; &")
    }

    // MARK: - Classes

    @Test("an annotation is read wherever Mermaid reads one")
    func annotations() {
        let diagram = parse("""
        class A {
            <<interface>>
            +x
        }
        class B { <<enum>>
            RED
        }
        class C <<service>>
        <<abstract>> D
        E : <<entity>>
        """)
        #expect(diagram.node("A")?.annotations == ["interface"])
        #expect(diagram.node("A")?.attributes.map(\.text) == ["+x"])
        #expect(diagram.node("B")?.annotations == ["enum"])
        #expect(diagram.node("B")?.attributes.map(\.text) == ["RED"])
        #expect(diagram.node("C")?.annotations == ["service"])
        #expect(diagram.node("D")?.annotations == ["abstract"])
        #expect(diagram.node("E")?.annotations == ["entity"])
    }

    @Test("a label, backticks, a style suffix and a one-line body")
    func classForms() {
        let diagram = parse("""
        class Animal["Animal with a label"]
        class `Car Class`
        class Hot:::warm {
            +heat()
        }
        class Empty {}
        class Inline { +x }
        Hot:::warm --> `Car Class`
        """)
        #expect(diagram.node("Animal")?.label == "Animal with a label")
        #expect(diagram.node("Car Class")?.label == "Car Class")
        #expect(diagram.node("Hot")?.methods.map(\.text) == ["+heat()"])
        #expect(diagram.node("Hot")?.attributes.isEmpty == true)
        #expect(diagram.node("Empty")?.attributes.isEmpty == true)
        #expect(diagram.node("Inline")?.attributes.map(\.text) == ["+x"])
        #expect(diagram.relations.count == 1)
        #expect(diagram.nodes.map(\.id) == ["Animal", "Car Class", "Hot", "Empty", "Inline"])
    }

    @Test("no semicolon splits a statement, so a member's reference survives whole")
    func noSemicolonSplit() {
        let node = parse("A : +List&lt;int&gt; items").node("A")
        #expect(node?.attributes.map(\.text) == ["+List<int> items"])
    }
}

// MARK: - Notes, namespaces and the rest

extension MermaidClassParserTests {
    @Test("a note for a class is a box with a dotted line to it, and a bare note floats")
    func notes() {
        let diagram = parse(
            "note \"floating\"\nnote for Duck \"can fly<br>can swim<br/>can &lt;dive&gt;\""
        )
        let notes = diagram.nodes.filter { $0.kind == .note }
        #expect(notes.map(\.lines) == [["floating"], ["can fly", "can swim", "can <dive>"]])
        #expect(diagram.relations.count == 1)
        let link = diagram.relations[0]
        #expect(link.isNoteLink)
        #expect(link.isDashed)
        #expect(diagram.nodes[link.from].kind == .note)
        #expect(diagram.nodes[link.to].id == "Duck")
    }

    @Test("only a class statement puts a class in a namespace, and dotted names nest")
    func namespaces() {
        let diagram = parse("""
        namespace Company.Engineering.Backend {
            class Developer
        }
        namespace Company.Engineering.Frontend {
            class Designer
            Designer --> Outsider
        }
        namespace Platform {
            namespace Auth {
                class UserService
            }
            class Gateway
        }
        namespace Auth2["Authentication Service"] {
            class TokenService
        }
        """)
        let ids = diagram.namespaces.map(\.id)
        #expect(ids == [
            "Company", "Company.Engineering", "Company.Engineering.Backend",
            "Company.Engineering.Frontend", "Platform", "Platform.Auth", "Auth2"
        ])
        #expect(diagram.namespaces.map(\.title) == [
            "Company", "Engineering", "Backend", "Frontend", "Platform", "Auth",
            "Authentication Service"
        ])
        #expect(diagram.namespaces.map(\.parent) == [nil, 0, 1, 1, nil, 4, nil])
        func home(_ id: String) -> String? {
            diagram.node(id)?.namespace.map { diagram.namespaces[$0].id }
        }
        #expect(home("Developer") == "Company.Engineering.Backend")
        #expect(home("Designer") == "Company.Engineering.Frontend")
        #expect(home("Outsider") == nil)
        #expect(home("UserService") == "Platform.Auth")
        #expect(home("Gateway") == "Platform")
        #expect(home("TokenService") == "Auth2")
    }

    @Test("styling and interaction are named as undrawn, and direction is read")
    func undrawnAndDirection() {
        let diagram = parse("""
        direction RL
        A --> B
        click A href "https://example.com"
        link B "https://example.com"
        callback A "cb"
        style A fill:#f9f
        classDef hot fill:#f00
        cssClass "A" hot
        accTitle: hidden
        """)
        #expect(diagram.direction == .rightLeft)
        #expect(diagram.undrawn == ["callback", "classDef", "click", "cssClass", "link", "style"])
        #expect(diagram.nodes.map(\.id) == ["A", "B"])
    }

    @Test("the corpus's shape: namespaces of enums and members written with references")
    func corpusShape() {
        let diagram = parse("""
                namespace Options {
            class Description {
            &lt;&lt;ro&gt;&gt; +string Id
            &lt;&lt;rw&gt;&gt; +Source Kind
            }
            class Source { <<enum>>
            First = 0
            Second = 1
            }
         }
                namespace Acquisition {
            class Acquirer { <<interface>>
            +Task&lt;Result&gt; GetAsync(IEnumerable&lt;string&gt; scopes, Options options)
            }
         }
            Description *-- "Kind" Source : Has
            Description --> "Acquirer" Acquirer : Uses
           Acquirer -->  Description : parametrized by
        """)
        #expect(diagram.namespaces.map(\.id) == ["Options", "Acquisition"])
        #expect(diagram.nodes.map(\.id) == ["Description", "Source", "Acquirer"])
        #expect(diagram.node("Source")?.annotations == ["enum"])
        #expect(diagram.node("Source")?.attributes.map(\.text) == ["First = 0", "Second = 1"])
        #expect(diagram.node("Acquirer")?.methods.map(\.text) == [
            "+Task<Result> GetAsync(IEnumerable<string> scopes, Options options)"
        ])
        #expect(diagram.relations.map(\.toCardinality) == ["Kind", "Acquirer", nil])
        #expect(diagram.relations.map(\.label) == ["Has", "Uses", "parametrized by"])
    }
}
