import Foundation

/// A placed sequence diagram, drawn (PLAN.md §M18 ▸ Slice 4).
///
/// Painting order is lifelines, activations, notes, messages, then headers — bottom to top, so a
/// message crosses a lifeline and a header box covers the line hanging from it.
enum MermaidSequenceSVG {
    static func svg(_ drawing: MermaidSequenceDrawing, scale: Double = 1) -> String {
        let body = drawing.participants.map { lifeline($0, bottom: drawing.lifelineBottom) }.joined()
            + drawing.activations.map { MermaidSVG.rect($0, classes: "mm-activation") }.joined()
            + drawing.notes.map(note).joined()
            + drawing.messages.map(message).joined()
            + drawing.participants.map(header).joined()
        return MermaidSVG.document(
            width: drawing.width,
            height: drawing.height,
            body: body,
            classes: "mermaid mermaid-sequence",
            scale: scale
        )
    }

    private static func lifeline(
        _ participant: MermaidSequenceDrawing.Participant,
        bottom: Double
    ) -> String {
        MermaidSVG.line(
            [
                MermaidPoint(x: participant.frame.midX, y: participant.frame.maxY),
                MermaidPoint(x: participant.frame.midX, y: bottom)
            ],
            classes: "mm-lifeline"
        )
    }

    /// An actor gets a stick figure above its box, which is the one thing that distinguishes
    /// `actor A` from `participant A` — so it is drawn rather than left as a class nothing uses.
    private static func header(_ participant: MermaidSequenceDrawing.Participant) -> String {
        MermaidSVG.rect(participant.frame, classes: "mm-participant", radius: 4)
            + MermaidSVG.text(
                participant.label,
                at: participant.frame.center,
                classes: "mm-label"
            )
            + (participant.isActor ? actor(participant.frame) : "")
    }

    private static func actor(_ frame: MermaidRect) -> String {
        let x = frame.midX
        let feet = frame.y - 3
        let head = feet - 16
        return """
        <circle class="mm-actor" cx="\(MermaidSVG.number(x))" cy="\(MermaidSVG.number(head))" r="3.5"/>
        """
            + MermaidSVG.line(
                [MermaidPoint(x: x, y: head + 4), MermaidPoint(x: x, y: feet - 4)],
                classes: "mm-actor"
            )
            + MermaidSVG.line(
                [MermaidPoint(x: x - 5, y: head + 8), MermaidPoint(x: x + 5, y: head + 8)],
                classes: "mm-actor"
            )
            + MermaidSVG.line(
                [
                    MermaidPoint(x: x - 4, y: feet),
                    MermaidPoint(x: x, y: feet - 4),
                    MermaidPoint(x: x + 4, y: feet)
                ],
                classes: "mm-actor"
            )
    }

    private static func note(_ note: MermaidSequenceDrawing.Note) -> String {
        MermaidSVG.rect(note.frame, classes: "mm-note", radius: 3)
            + MermaidSVG.text(note.text, at: note.frame.center, classes: "mm-note-label")
    }

    private static func message(_ message: MermaidSequenceDrawing.Message) -> String {
        let dashed = message.style.isDashed ? " mm-edge-dotted" : " mm-edge-solid"
        var parts = [MermaidSVG.line(message.points, classes: "mm-edge\(dashed)")]
        if let last = message.points.last, message.points.count >= 2 {
            let previous = message.points[message.points.count - 2]
            parts.append(
                MermaidSVG.tip(tip(for: message.style), at: last, from: previous, classes: "mm-tip")
            )
        }
        if !message.text.isEmpty {
            parts.append(MermaidSVG.text(
                message.text,
                at: message.labelCentre,
                classes: message.isSelf ? "mm-edge-label mm-edge-label-start" : "mm-edge-label"
            ))
        }
        return parts.joined()
    }

    /// The head an arrow style ends in. An **open** arrow (`->`) and a filled one (`->>`) are drawn
    /// the same triangle here: the distinction mermaid draws is a stroke against a fill, and the
    /// emitter writes no colours, so it would have to invent one. The line style — solid against
    /// dashed — is the difference that survives, and it is the one that carries the meaning.
    private static func tip(for style: MermaidSequence.MessageStyle) -> MermaidFlowchart.Tip {
        if case .crossed = style { return .cross }
        return .arrow
    }
}
