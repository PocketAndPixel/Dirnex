import Foundation

/// A placed flowchart, drawn (PLAN.md §M18 ▸ Slice 4).
///
/// Edges first, then nodes, so a line that passes near a box is covered by it rather than crossing
/// its label — SVG has no z-index, and painting order is the whole of the answer.
enum MermaidFlowchartSVG {
    static func svg(_ drawing: MermaidFlowchartDrawing, scale: Double = 1) -> String {
        let body = drawing.edges.map(edge).joined() + drawing.nodes.map(node).joined()
        return MermaidSVG.document(
            width: drawing.width,
            height: drawing.height,
            body: body,
            classes: "mermaid mermaid-flowchart",
            scale: scale
        )
    }

    private static func node(_ node: MermaidFlowchartDrawing.Node) -> String {
        shape(node) + MermaidSVG.text(node.label, at: node.frame.center, classes: "mm-label")
    }

    private static func shape(_ node: MermaidFlowchartDrawing.Node) -> String {
        let frame = node.frame
        switch node.shape {
        case .rectangle:
            return MermaidSVG.rect(frame, classes: "mm-node")
        case .rounded:
            return MermaidSVG.rect(frame, classes: "mm-node", radius: 6)
        case .circle:
            return """
            <ellipse class="mm-node" cx="\(MermaidSVG.number(frame.midX))" \
            cy="\(MermaidSVG.number(frame.midY))" rx="\(MermaidSVG.number(frame.width / 2))" \
            ry="\(MermaidSVG.number(frame.height / 2))"/>
            """
        case .diamond:
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
        case .subroutine:
            // The outer box plus the two inner bars that make it read as a call rather than a step.
            let inset = 8.0
            return MermaidSVG.rect(frame, classes: "mm-node")
                + MermaidSVG.line(
                    [
                        MermaidPoint(x: frame.x + inset, y: frame.y),
                        MermaidPoint(x: frame.x + inset, y: frame.maxY)
                    ],
                    classes: "mm-node-bar"
                )
                + MermaidSVG.line(
                    [
                        MermaidPoint(x: frame.maxX - inset, y: frame.y),
                        MermaidPoint(x: frame.maxX - inset, y: frame.maxY)
                    ],
                    classes: "mm-node-bar"
                )
        }
    }

    private static func edge(_ edge: MermaidFlowchartDrawing.Edge) -> String {
        let stroke = "mm-edge mm-edge-\(edge.stroke.rawValue)"
        var parts = [MermaidSVG.line(edge.points, classes: stroke)]
        // A tip is aimed along the polyline's *last* segment, not from end to end — on a bent edge
        // those point in different directions, and the arrowhead would sit askew on the border.
        parts.append(MermaidSVG.tip(
            edge.head, at: edge.end, from: edge.points[edge.points.count - 2], classes: "mm-tip"
        ))
        parts.append(
            MermaidSVG.tip(edge.tail, at: edge.start, from: edge.points[1], classes: "mm-tip")
        )
        if let label = edge.label {
            // A plate under the label, because the line runs through where the text sits. Its class
            // is the page background's, so it hides the line in either appearance.
            parts.append(MermaidSVG.rect(
                plate(around: edge.labelCentre, text: label),
                classes: "mm-edge-label-plate",
                radius: 3
            ))
            parts.append(MermaidSVG.text(label, at: edge.labelCentre, classes: "mm-edge-label"))
        }
        return parts.joined()
    }

    /// The plate is sized from the *character count* rather than from the metric, on purpose: it
    /// only has to be about right, and threading the metric through the emitter would make the
    /// drawing depend on it twice — once for the layout the caller already did, and once here,
    /// where a disagreement between the two would be invisible until it looked wrong.
    private static func plate(around centre: MermaidPoint, text: String) -> MermaidRect {
        let width = Double(text.count) * 6.6 + 8
        let height = 15.0
        return MermaidRect(
            x: centre.x - width / 2,
            y: centre.y - height / 2,
            width: width,
            height: height
        )
    }
}
