import Foundation
import Testing

@testable import DirnexCore

/// The sequence-diagram half of the same parser (PLAN.md §M18 ▸ Slice 4).
///
/// A second suite rather than a longer one: the two dialects share an entry point and nothing else,
/// and `MermaidParserTests` was already at SwiftLint's type-body ceiling.
@Suite("Mermaid sequence parser")
struct MermaidSequenceParserTests {
    private func sequence(_ source: String) -> MermaidSequence? {
        guard case let .sequence(diagram) = MermaidParser.parse(source) else { return nil }
        return diagram
    }

    @Test("participants, aliases and actors")
    func participants() {
        let diagram = sequence("""
        sequenceDiagram
        participant A as Alice
        actor B
        A->>B: Hello
        """)
        #expect(diagram?.participants.map(\.id) == ["A", "B"])
        #expect(diagram?.participants.map(\.label) == ["Alice", "B"])
        #expect(diagram?.participants.map(\.isActor) == [false, true])
    }

    @Test("an undeclared participant is placed where it is first mentioned")
    func implicitParticipants() {
        let diagram = sequence("""
        sequenceDiagram
        A->>B: one
        C->>A: two
        """)
        #expect(diagram?.participants.map(\.id) == ["A", "B", "C"])
    }

    @Test("every arrow in the subset")
    func messageStyles() {
        func style(_ arrow: String) -> MermaidSequence.MessageStyle? {
            guard case let .message(_, _, _, style)? = sequence(
                "sequenceDiagram\nA\(arrow)B: hi"
            )?.events.first else { return nil }
            return style
        }
        #expect(style("->>") == .solidArrow)
        #expect(style("-->>") == .dashedArrow)
        #expect(style("->") == .solidOpen)
        #expect(style("-->") == .dashedOpen)
        #expect(style("--x") == .crossed(isDashed: true))
        #expect(style("-x") == .crossed(isDashed: false))
    }

    @Test("the arrow is found before the colon, so a message may talk about arrows")
    func arrowBeatsColon() {
        guard case let .message(from, to, text, _)? = sequence(
            "sequenceDiagram\nA->>B: use -->> for a reply: really"
        )?.events.first else {
            Issue.record("no message parsed")
            return
        }
        #expect(from == "A")
        #expect(to == "B")
        #expect(text == "use -->> for a reply: really")
    }

    @Test("a hyphen in a participant id is not an arrow")
    func hyphenatedParticipant() {
        guard case let .message(from, to, _, _)? = sequence(
            "sequenceDiagram\nauth-service->>web-app: token"
        )?.events.first else {
            Issue.record("no message parsed")
            return
        }
        #expect(from == "auth-service")
        #expect(to == "web-app")
    }

    @Test("activations, both spellings")
    func activations() {
        let explicit = sequence("""
        sequenceDiagram
        A->>B: go
        activate B
        B-->>A: done
        deactivate B
        """)
        #expect(explicit?.events.count == 4)
        #expect(explicit?.events[1] == .activate("B"))
        #expect(explicit?.events[3] == .deactivate("B"))

        // The `+`/`-` suffix rides on the target and must not end up in its name.
        let suffixed = sequence("sequenceDiagram\nA->>+B: go\nB-->>-A: done")
        #expect(suffixed?.participants.map(\.id) == ["A", "B"])
        #expect(suffixed?.events[1] == .activate("B"))
        #expect(suffixed?.events[3] == .deactivate("A"))
    }

    @Test("notes, and the three placements")
    func notes() {
        let diagram = sequence("""
        sequenceDiagram
        participant A
        participant B
        Note over A,B: both of them
        Note right of A: just A
        Note left of B: just B
        """)
        #expect(diagram?.events == [
            .note(placement: .over, participants: ["A", "B"], text: "both of them"),
            .note(placement: .rightOf, participants: ["A"], text: "just A"),
            .note(placement: .leftOf, participants: ["B"], text: "just B")
        ])
    }

    @Test("a grouping construct keeps its messages and reports its frame")
    func sequenceGroupingIsReported() {
        let diagram = sequence("""
        sequenceDiagram
        loop every minute
        A->>B: poll
        end
        alt found
        B-->>A: yes
        else missing
        B-->>A: no
        end
        """)
        // Three messages survive; the boxes around them are what is reported.
        #expect(diagram?.events.count == 3)
        #expect(diagram?.undrawn == ["alt", "loop"])
    }
}
