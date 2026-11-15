import Foundation

/// A placed state diagram, drawn (PLAN.md §M39 ▸ Slice 13).
///
/// Painted back to front: composites and the dashed lines between regions, then notes, then
/// transitions, then every other state, so a line runs under the boxes it meets and a label's plate
/// sits over the lines it crosses. Class names and `currentColor` only, as every diagram here is
/// (`MermaidSVG`): the start dot and the bars are filled with the text color, which is what makes
/// them read in both appearances.
enum MermaidStateSVG {
    static func svg(_ drawing: MermaidStateDrawing, scale: Double = 1) -> String {
        let composites = drawing.nodes.filter(\.isComposite)
        let others = drawing.nodes.filter { !$0.isComposite }
        let body = composites.map(node).joined()
            + drawing.dividers.map { MermaidSVG.line($0, classes: "mm-state-divider") }.joined()
            + drawing.notes.map(note).joined()
            + drawing.edges.map(edge).joined()
            + others.map(node).joined()
        return MermaidSVG.document(
            width: drawing.width,
            height: drawing.height,
            body: body,
            classes: "mermaid mermaid-state",
            scale: scale
        )
    }

    private static func node(_ node: MermaidStateDrawing.Node) -> String {
        let frame = node.frame
        switch node.kind {
        case .start:
            return circle(frame.center, radius: frame.width / 2, classes: "mm-state-dot")
        case .end:
            return circle(frame.center, radius: frame.width / 2, classes: "mm-state-ring")
                + circle(frame.center, radius: frame.width / 2 - 3, classes: "mm-state-dot")
        case .choice:
            let points = [
                MermaidPoint(x: frame.midX, y: frame.y),
                MermaidPoint(x: frame.maxX, y: frame.midY),
                MermaidPoint(x: frame.midX, y: frame.maxY),
                MermaidPoint(x: frame.x, y: frame.midY)
            ]
            let path = points
                .map { "\(MermaidSVG.number($0.x)),\(MermaidSVG.number($0.y))" }
                .joined(separator: " ")
            return "<polygon class=\"mm-node\" points=\"\(path)\"/>"
        case .fork, .join:
            return MermaidSVG.rect(frame, classes: "mm-state-bar", radius: 2)
        case .state:
            let rule = node.ruleY.map {
                MermaidSVG.line(
                    [MermaidPoint(x: frame.x, y: $0), MermaidPoint(x: frame.maxX, y: $0)],
                    classes: "mm-state-rule"
                )
            } ?? ""
            return MermaidSVG.rect(frame, classes: "mm-node", radius: node.isComposite ? 8 : 6)
                + rule
                + node.texts.map { MermaidSVG.text($0.string, at: $0.center, classes: "mm-label") }
                .joined()
        }
    }

    private static func note(_ note: MermaidStateDrawing.Note) -> String {
        MermaidSVG.line(note.link, classes: "mm-note-link")
            + MermaidSVG.rect(note.frame, classes: "mm-note", radius: 3)
            + note.texts.map { MermaidSVG.text($0.string, at: $0.center, classes: "mm-note-label") }
            .joined()
    }

    private static func edge(_ edge: MermaidStateDrawing.Edge) -> String {
        var parts = [MermaidSVG.line(edge.points, classes: "mm-edge mm-edge-solid")]
        parts.append(MermaidSVG.tip(
            .arrow,
            at: edge.end,
            from: edge.points[edge.points.count - 2],
            classes: "mm-tip"
        ))
        if let label = edge.label {
            parts.append(MermaidSVG.edgeLabel(label, at: edge.labelCenter, plated: !edge.isLoop))
        }
        return parts.joined()
    }

    private static func circle(_ center: MermaidPoint, radius: Double, classes: String) -> String {
        """
        <circle class="\(classes)" cx="\(MermaidSVG.number(center.x))" \
        cy="\(MermaidSVG.number(center.y))" r="\(MermaidSVG.number(radius))"/>
        """
    }
}
