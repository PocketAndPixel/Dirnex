import Foundation

/// A placed class diagram, drawn (PLAN.md §M39 ▸ Slice 14).
///
/// Painted back to front: namespaces, then lines with their markers and labels, then boxes, so a
/// line meets a box at its border and a hollow marker's background hides the line inside it. Class
/// names and `currentColor` only (`MermaidSVG`).
enum MermaidClassSVG {
    static func svg(_ drawing: MermaidClassDrawing, scale: Double = 1) -> String {
        let body = drawing.groups.map(group).joined()
            + drawing.edges.map(edge).joined()
            + drawing.boxes.map(box).joined()
        return MermaidSVG.document(
            width: drawing.width,
            height: drawing.height,
            body: body,
            classes: "mermaid mermaid-class",
            scale: scale
        )
    }

    private static func group(_ group: MermaidClassDrawing.Group) -> String {
        MermaidSVG.rect(group.frame, classes: "mm-group", radius: 4) + text(group.title)
    }

    private static func box(_ box: MermaidClassDrawing.Box) -> String {
        let frame = box.frame
        let outline: String
        switch box.kind {
        case .interface: outline = ""
        case .note: outline = MermaidSVG.rect(frame, classes: "mm-note", radius: 3)
        case .class: outline = MermaidSVG.rect(frame, classes: "mm-node")
        }
        let rules = box.rules.map {
            MermaidSVG.line(
                [MermaidPoint(x: frame.x, y: $0), MermaidPoint(x: frame.maxX, y: $0)],
                classes: "mm-box-rule"
            )
        }.joined()
        return outline + rules + box.texts.map(text).joined()
    }

    static func text(_ text: MermaidClassDrawing.Text) -> String {
        let classes: String
        switch text.style {
        case .name: classes = "mm-label mm-class-name"
        case .annotation, .interface: classes = "mm-label"
        case let .member(isStatic, isAbstract):
            classes = "mm-label"
                + (isStatic ? " mm-class-static" : "")
                + (isAbstract ? " mm-class-abstract" : "")
        case .note: classes = "mm-note-label"
        case .groupTitle: classes = "mm-group-label"
        case .cardinality: classes = "mm-edge-label"
        }
        return MermaidSVG.text(
            text.string,
            at: text.point,
            classes: classes,
            anchor: text.isLeading ? "start" : "middle"
        )
    }

    private static func edge(_ edge: MermaidClassDrawing.Edge) -> String {
        let stroke = edge.isNoteLink
            ? "mm-note-link"
            : "mm-edge " + (edge.isDashed ? "mm-edge-dotted" : "mm-edge-solid")
        let points = edge.points
        var parts = [MermaidSVG.line(points, classes: stroke)]
        if points.count >= 2 {
            parts.append(
                MermaidMarker.classEnd(edge.toEnd, at: edge.end, from: points[points.count - 2])
            )
            parts.append(MermaidMarker.classEnd(edge.fromEnd, at: edge.start, from: points[1]))
        }
        if let label = edge.label {
            parts.append(MermaidSVG.edgeLabel(label, at: edge.labelCenter, plated: !edge.isLoop))
        }
        parts += edge.cardinalities.map(text)
        return parts.joined()
    }
}

/// The marks a class or ER line ends in, each drawn along the line's last segment with its tip on
/// the box's border (PLAN.md §M39 ▸ Slice 14).
///
/// Polygons and polylines in three classes, never a `<marker>`, for `MermaidSVG.tip`'s reason: a
/// marker would need a color written into it. A hollow mark is filled with the page's background so
/// the line under it does not show through.
enum MermaidMarker {
    /// A unit step along the line toward `point` and the step across it.
    private struct Axis {
        let point: MermaidPoint
        let ux: Double
        let uy: Double

        init?(at point: MermaidPoint, from origin: MermaidPoint) {
            let dx = point.x - origin.x
            let dy = point.y - origin.y
            let length = (dx * dx + dy * dy).squareRoot()
            guard length > 0.001 else { return nil }
            self.point = point
            ux = dx / length
            uy = dy / length
        }

        /// The point `back` out of the box along the line and `side` across it.
        func at(back: Double, side: Double = 0) -> MermaidPoint {
            MermaidPoint(x: point.x - ux * back - uy * side, y: point.y - uy * back + ux * side)
        }
    }

    static func classEnd(
        _ end: MermaidClassDiagram.End,
        at point: MermaidPoint,
        from origin: MermaidPoint
    ) -> String {
        guard let axis = Axis(at: point, from: origin) else { return "" }
        switch end {
        case .none:
            return ""
        case .arrow:
            return MermaidSVG.tip(.arrow, at: point, from: origin, classes: "mm-tip")
        case .extension:
            return polygon(
                [axis.at(back: 0), axis.at(back: 13, side: 7), axis.at(back: 13, side: -7)],
                hollow: true
            )
        case .composition, .aggregation:
            return polygon(
                [
                    axis.at(back: 0),
                    axis.at(back: 8, side: 5),
                    axis.at(back: 16),
                    axis.at(back: 8, side: -5)
                ],
                hollow: end == .aggregation
            )
        case .lollipop:
            return circle(axis.at(back: 5), radius: 5)
        }
    }

    /// An ER end: the maximum touches the box (a bar, or a crow's foot spreading onto it) and the
    /// minimum sits further out (a bar, or a ring), as Mermaid's crow's foot reads.
    static func erEnd(
        _ cardinality: MermaidERDiagram.Cardinality,
        at point: MermaidPoint,
        from origin: MermaidPoint
    ) -> String {
        guard let axis = Axis(at: point, from: origin) else { return "" }
        let many = cardinality == .zeroOrMore || cardinality == .oneOrMore
        let maximum = many
            ? MermaidSVG.line(
                [axis.at(back: 0, side: 7), axis.at(back: 12), axis.at(back: 0, side: -7)],
                classes: "mm-marker-line"
            )
            : bar(axis, back: 6)
        let minimum: String
        switch cardinality {
        case .zeroOrOne: minimum = circle(axis.at(back: 15), radius: 4.5)
        case .zeroOrMore: minimum = circle(axis.at(back: 19), radius: 4.5)
        case .exactlyOne: minimum = bar(axis, back: 11)
        case .oneOrMore: minimum = bar(axis, back: 17)
        }
        return maximum + minimum
    }

    private static func bar(_ axis: Axis, back: Double) -> String {
        MermaidSVG.line(
            [axis.at(back: back, side: 7), axis.at(back: back, side: -7)],
            classes: "mm-marker-line"
        )
    }

    private static func polygon(_ points: [MermaidPoint], hollow: Bool) -> String {
        let path = points
            .map { "\(MermaidSVG.number($0.x)),\(MermaidSVG.number($0.y))" }
            .joined(separator: " ")
        let classes = hollow ? "mm-marker-hollow" : "mm-marker-filled"
        return "<polygon class=\"\(classes)\" points=\"\(path)\"/>"
    }

    private static func circle(_ center: MermaidPoint, radius: Double) -> String {
        """
        <circle class="mm-marker-hollow" cx="\(MermaidSVG.number(center.x))" \
        cy="\(MermaidSVG.number(center.y))" r="\(MermaidSVG.number(radius))"/>
        """
    }
}
