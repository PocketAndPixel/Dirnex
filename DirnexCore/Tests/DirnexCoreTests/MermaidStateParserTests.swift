import Foundation
import Testing

@testable import DirnexCore

/// Reading a state diagram (PLAN.md §M39 ▸ Slice 13).
///
/// The rules here are Mermaid's, read off Mermaid 12.3 rendering on its own documentation page
/// rather than off its docs, which state few of them: how many start dots a diagram has, what a
/// second description does, and which composite a state mentioned in two places belongs to.
@Suite("Mermaid state diagram parsing")
struct MermaidStateParserTests {
    private func diagram(_ source: String) -> MermaidStateDiagram? {
        guard case let .state(diagram) = MermaidParser.parse(source) else { return nil }
        return diagram
    }

    private func ids(_ diagram: MermaidStateDiagram?, in region: MermaidStateDiagram.Region?) -> [
        String
    ] {
        guard let diagram, let region else { return [] }
        return region.states.map { diagram.states[$0].id }.filter { !$0.hasPrefix("\u{0}") }
    }

    private func kinds(_ diagram: MermaidStateDiagram?) -> [MermaidStateDiagram.Kind] {
        diagram?.states.map(\.kind) ?? []
    }

    // MARK: - The header

    @Test("both header spellings are a state diagram, and an empty one falls back")
    func header() {
        #expect(diagram("stateDiagram-v2\n[*] --> Still") != nil)
        #expect(diagram("stateDiagram\n[*] --> Still") != nil)
        #expect(MermaidParser.parse("stateDiagram-v2") == .unsupported("stateDiagram-v2"))
        #expect(MermaidParser.parse("stateDiagram\n%% nothing") == .unsupported("stateDiagram"))
    }

    // MARK: - Start and end

    @Test("every [*] in a region shares one start and one end")
    func oneStartAndEndPerRegion() {
        let parsed = diagram("""
        stateDiagram-v2
            [*] --> Still
            Still --> [*]
            Still --> Moving
            Moving --> Still
            Moving --> Crash
            Crash --> [*]
        """)
        // Mermaid's simple sample draws five nodes: the three states, one start, one end.
        #expect(kinds(parsed).count(where: { $0 == .start }) == 1)
        #expect(kinds(parsed).count(where: { $0 == .end }) == 1)
        #expect(parsed?.states.count == 5)
        #expect(parsed?.transitions.count == 6)
    }

    @Test("a composite's inside has a start and an end of its own")
    func compositeHasItsOwnStart() {
        let parsed = diagram("""
        stateDiagram-v2
            [*] --> First
            state First {
                [*] --> second
                second --> [*]
            }
        """)
        #expect(kinds(parsed).count(where: { $0 == .start }) == 2)
        #expect(kinds(parsed).count(where: { $0 == .end }) == 1)
        let first = parsed?.state("First")
        #expect(first?.isComposite == true)
        // The inside holds its own start, `second`, and its own end.
        #expect(first?.regions.first?.states.count == 3)
    }

    // MARK: - Descriptions

    @Test("a description replaces the name, and a second makes a titled box")
    func descriptions() {
        let parsed = diagram("""
        stateDiagram-v2
            s1 : first
            s1 : second
            s2 : only
            state "Quoted" as s3
            s3 : extra
            t : one
            t : two
            t : three
        """)
        #expect(parsed?.state("s1")?.descriptions == ["first", "second"])
        #expect(parsed?.state("s1")?.title == "first")
        #expect(parsed?.state("s2")?.title == "only")
        #expect(parsed?.state("s3")?.descriptions == ["Quoted", "extra"])
        #expect(parsed?.state("t")?.descriptions == ["one", "two", "three"])
        // A marker's brackets inside a quoted name are part of the name.
        let quoted = diagram("stateDiagram-v2\nstate \"Use <<this>>\" as s <<choice>>")
        #expect(quoted?.state("s")?.title == "Use <<this>>")
        #expect(quoted?.state("s")?.kind == .choice)
    }

    @Test("a composite takes its description as its title")
    func compositeTitle() {
        let parsed = diagram("""
        stateDiagram-v2
            NamedComposite: Another Composite
            state NamedComposite {
                [*] --> namedSimple
            }
        """)
        #expect(parsed?.state("NamedComposite")?.title == "Another Composite")
    }

    @Test("a description may hold an arrow, and a label a colon")
    func colonsAndArrows() {
        let parsed = diagram("""
        stateDiagram-v2
            s1 : a --> b
            x --> y : label: with colon
        """)
        #expect(parsed?.state("s1")?.title == "a --> b")
        #expect(parsed?.state("a") == nil)
        #expect(parsed?.transitions.map(\.label) == ["label: with colon"])
    }

    @Test("a semicolon is part of a label, not a statement break")
    func noSemicolonSplit() {
        // The flowchart's splitter would read a state called `y` into this diagram.
        let parsed = diagram("stateDiagram-v2\nx --> z : first; y")
        #expect(parsed?.transitions.first?.label == "first; y")
        #expect(parsed?.state("y") == nil)
    }

    // MARK: - Which composite a state is in

    @Test(
        "a state belongs to the last block that mentions it, and the top level never claims it back"
    )
    func membership() {
        // Mermaid put `inner1` inside `Outer` although the top level named it first.
        let parsed = diagram("""
        stateDiagram-v2
            [*] --> x
            x --> inner1
            state Outer {
                [*] --> inner1
                inner1 --> [*]
            }
            x --> inner1
        """)
        let outer = parsed?.state("Outer")
        #expect(ids(parsed, in: outer?.regions.first) == ["inner1"])
        #expect(ids(parsed, in: parsed?.regions.first) == ["x", "Outer"])
    }

    @Test("a block that would put a state inside itself is refused")
    func noCycles() {
        let parsed = diagram("""
        stateDiagram-v2
            state A {
                B --> c
            }
            state B {
                A --> d
            }
        """)
        // B is inside A, so A cannot also be inside B: the second claim is refused and A stays at
        // the top level, where the drawing can reach it.
        #expect(ids(parsed, in: parsed?.regions.first) == ["A"])
        let insideA = ids(parsed, in: parsed?.state("A")?.regions.first)
        #expect(insideA.contains("B"))
    }

    @Test("an empty block leaves a simple state")
    func emptyBlock() {
        let parsed = diagram("stateDiagram-v2\nstate Lonely {\n}\nLonely --> Other")
        #expect(parsed?.state("Lonely")?.isComposite == false)
    }

    // MARK: - Regions, directions, markers

    @Test("-- splits a composite into regions, each with its own start")
    func concurrency() {
        let parsed = diagram("""
        stateDiagram-v2
            [*] --> Active
            state Active {
                [*] --> NumLockOff
                NumLockOff --> NumLockOn : EvNumLockPressed
                --
                [*] --> CapsLockOff
                --
                [*] --> ScrollLockOff
            }
        """)
        let active = parsed?.state("Active")
        #expect(active?.regions.count == 3)
        #expect(ids(parsed, in: active?.regions[1]) == ["CapsLockOff"])
        #expect(kinds(parsed).count(where: { $0 == .start }) == 4)
    }

    @Test("an inside runs top to bottom unless its own block says otherwise")
    func directions() {
        let parsed = diagram("""
        stateDiagram
            direction LR
            state B {
              a --> b
            }
            state C {
              direction LR
              c --> d
            }
        """)
        #expect(parsed?.direction == .leftRight)
        #expect(parsed?.state("B")?.insideDirection == .topDown)
        #expect(parsed?.state("C")?.insideDirection == .leftRight)
        #expect(diagram("stateDiagram\nA --> B")?.direction == .topDown)
    }

    @Test("choice, fork and join, in either bracket spelling")
    func markers() {
        let parsed = diagram("""
        stateDiagram-v2
            state if_state <<choice>>
            state fork_state <<fork>>
            state join_state [[join]]
            if_state --> fork_state
        """)
        #expect(parsed?.state("if_state")?.kind == .choice)
        #expect(parsed?.state("fork_state")?.kind == .fork)
        #expect(parsed?.state("join_state")?.kind == .join)
    }

    // MARK: - Notes

    @Test("a note sits on one side of its state, on one line or several")
    func notes() {
        let parsed = diagram("""
        stateDiagram-v2
            State1: The state with a note
            note right of State1
                Important information! You can write
                notes.
            end note
            State1 --> State2
            note left of State2 : This is the note to the left.
        """)
        #expect(parsed?.state("State1")?.notes == [MermaidStateDiagram.Note(
            side: .right,
            lines: ["Important information! You can write", "notes."]
        )])
        #expect(parsed?.state("State2")?.notes == [MermaidStateDiagram.Note(
            side: .left,
            lines: ["This is the note to the left."]
        )])
        // The note's lines are not read as states.
        #expect(parsed?.states.count == 2)
    }

    @Test("a note on nothing is named, and a state called note is still a state")
    func floatingNote() {
        let parsed = diagram("stateDiagram-v2\nnote \"floating\" as N1\nnote --> x")
        #expect(parsed?.undrawn == ["note"])
        #expect(parsed?.state("note") != nil)
    }

    // MARK: - What is not drawn

    @Test("styling is named rather than drawn, and its suffix is not part of a name")
    func styling() {
        let parsed = diagram("""
        stateDiagram
            classDef badBadEvent fill:#f00
            [*] --> Still:::notMoving
            Crash:::badBadEvent --> [*]
            class Crash badBadEvent
            style Still fill:#fff
        """)
        #expect(parsed?.undrawn == ["class", "classDef", "style"])
        #expect(parsed?.state("Still") != nil)
        #expect(parsed?.state("Crash") != nil)
        #expect(parsed?.state("Still:::notMoving") == nil)
    }

    @Test("accessibility text is neither drawn nor read as a state")
    func accessibility() {
        let parsed = diagram("""
        stateDiagram
            accTitle: This is the accessible title
            accDescr: This is an accessible description
            accDescr {
                a longer one
                over lines
            }
            A --> B
        """)
        #expect(parsed?.states.map(\.id) == ["A", "B"])
        #expect(parsed?.undrawn == [])
    }
}
