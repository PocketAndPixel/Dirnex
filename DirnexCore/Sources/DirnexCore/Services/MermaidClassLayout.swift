import Foundation

/// A class diagram, placed (PLAN.md §M39 ▸ Slice 14).
struct MermaidClassDrawing: Equatable {
    enum Style: Equatable {
        /// A class's name, in bold.
        case name
        case annotation
        case member(isStatic: Bool, isAbstract: Bool)
        /// A lollipop interface's name, with no box around it.
        case interface
        case note
        case groupTitle
        case cardinality
    }

    struct Text: Equatable {
        let string: String
        /// Its center, or its left end for a member.
        let point: MermaidPoint
        let style: Style
        var isLeading = false
    }

    struct Box: Equatable {
        let kind: MermaidClassDiagram.Kind
        let frame: MermaidRect
        /// Where the lines between a class's compartments run, two for a class and none otherwise.
        let rules: [Double]
        let texts: [Text]
    }

    struct Group: Equatable {
        let frame: MermaidRect
        let title: Text
    }

    struct Edge: Equatable {
        let points: [MermaidPoint]
        let label: String?
        let labelCenter: MermaidPoint
        let fromEnd: MermaidClassDiagram.End
        let toEnd: MermaidClassDiagram.End
        let isDashed: Bool
        let isNoteLink: Bool
        let isLoop: Bool
        let cardinalities: [Text]

        var start: MermaidPoint { points[0] }
        var end: MermaidPoint { points[points.count - 1] }
    }

    let width: Double
    let height: Double
    let groups: [Group]
    /// One per node, in the diagram's order.
    let boxes: [Box]
    /// One per relation, in the diagram's order.
    let edges: [Edge]
}

/// Placing a class diagram (PLAN.md §M39 ▸ Slice 14): every box sized to what it holds, then laid out
/// by the state diagram's region layout through `MermaidBoxGraph`, a namespace taking part as a group.
enum MermaidClassLayout {
    /// Wider than a state diagram's: a class box is broad, and a line's end carries a marker and a
    /// cardinality between the box and the label's slot.
    static let spacing = MermaidLayered.Spacing(rankGap: 24, crossGap: 30, margin: 10)
    static let padX = 10.0
    static let padY = 6.0
    static let minimumWidth = 60.0
    static let interfacePad = 4.0
    static let notePadX = 8.0
    static let notePadY = 6.0

    static func lay(
        out diagram: MermaidClassDiagram,
        metric: MarkdownTextMetric
    ) -> MermaidClassDrawing {
        let (graph, order) = boxGraph(diagram, metric: metric)
        let (nodeAt, groupAt) = (order.boxAt, order.groupAt)
        let placed = graph.lay(metric: metric, spacing: spacing)
        let boxes = diagram.nodes.indices.map {
            box(diagram.nodes[$0], frame: placed.frames[nodeAt[$0]], metric: metric)
        }
        let groups = diagram.namespaces.indices.map { index in
            let frame = placed.frames[groupAt[index]]
            return MermaidClassDrawing.Group(
                frame: frame,
                title: MermaidClassDrawing.Text(
                    string: diagram.namespaces[index].title,
                    point: placed.titleCenters[groupAt[index]] ?? frame.center,
                    style: .groupTitle
                )
            )
        }
        let edges = zip(diagram.relations, placed.edges).map { relation, edge in
            MermaidClassDrawing.Edge(
                points: edge.points,
                label: relation.label,
                labelCenter: edge.labelCenter,
                fromEnd: relation.fromEnd,
                toEnd: relation.toEnd,
                isDashed: relation.isDashed,
                isNoteLink: relation.isNoteLink,
                isLoop: edge.isLoop,
                cardinalities: cardinalities(relation, edge: edge, metric: metric)
            )
        }
        return fitted(MermaidClassDrawing(
            width: placed.width,
            height: placed.height,
            groups: groups,
            boxes: boxes,
            edges: edges
        ), metric: metric)
    }

    /// The diagram as boxes and groups in one first-mention order — a namespace just before the
    /// first node mentioned after it opened — with where each node and namespace landed in it.
    private static func boxGraph(
        _ diagram: MermaidClassDiagram,
        metric: MarkdownTextMetric
    ) -> (MermaidBoxGraph, MermaidBoxOrder) {
        let order = MermaidBoxGraph.order(
            boxes: diagram.nodes.count,
            groupPositions: diagram.namespaces.map(\.position)
        )
        let (nodeAt, groupAt) = (order.boxAt, order.groupAt)
        let nodes = order.items.map { item -> MermaidBoxGraph.Node in
            if item.isGroup {
                let namespace = diagram.namespaces[item.index]
                return MermaidBoxGraph.Node(
                    box: nil,
                    title: namespace.title,
                    parent: namespace.parent.map { groupAt[$0] },
                    direction: nil
                )
            }
            let node = diagram.nodes[item.index]
            return MermaidBoxGraph.Node(
                box: size(of: node, metric: metric),
                title: node.label,
                parent: node.namespace.map { groupAt[$0] },
                direction: nil
            )
        }
        let links = diagram.relations.map {
            MermaidBoxGraph.Link(from: nodeAt[$0.from], to: nodeAt[$0.to], label: $0.label)
        }
        return (MermaidBoxGraph(direction: diagram.direction, nodes: nodes, links: links), order)
    }

    // MARK: - Boxes

    /// A class is its name over its attributes over its methods, each band padded and an empty one
    /// still drawn; an interface is its name; a note its lines.
    static func size(of node: MermaidClassDiagram.Node, metric: MarkdownTextMetric) -> MermaidSize {
        let line = metric.lineHeight
        switch node.kind {
        case .interface:
            return MermaidSize(
                width: metric.width(node.label) + 2 * interfacePad,
                height: line + 2 * interfacePad
            )
        case .note:
            return MermaidSize(
                width: (node.lines.map(metric.width).max() ?? 0) + 2 * notePadX,
                height: line * Double(max(node.lines.count, 1)) + 2 * notePadY
            )
        case .class:
            let widths = [metric.boldWidth(node.label)]
                + node.annotations.map { metric.width(guillemets($0)) }
                + (node.attributes + node.methods).map { metric.width($0.text) }
            let bands = Double(
                node.annotations.count + 1 + node.attributes.count + node.methods.count
            )
            return MermaidSize(
                width: max((widths.max() ?? 0) + 2 * padX, minimumWidth),
                height: line * bands + 6 * padY
            )
        }
    }

    /// `«interface»`, as Mermaid draws an annotation.
    static func guillemets(_ annotation: String) -> String {
        "«" + annotation + "»"
    }

    private static func box(
        _ node: MermaidClassDiagram.Node,
        frame: MermaidRect,
        metric: MarkdownTextMetric
    ) -> MermaidClassDrawing.Box {
        let line = metric.lineHeight
        func row(_ index: Int, from top: Double) -> Double { top + line * (Double(index) + 0.5) }
        switch node.kind {
        case .interface:
            let text = MermaidClassDrawing.Text(
                string: node.label,
                point: frame.center,
                style: .interface
            )
            return MermaidClassDrawing.Box(kind: .interface, frame: frame, rules: [], texts: [text])
        case .note:
            let texts = node.lines.enumerated().map { index, string in
                MermaidClassDrawing.Text(
                    string: string,
                    point: MermaidPoint(x: frame.midX, y: row(index, from: frame.y + notePadY)),
                    style: .note
                )
            }
            return MermaidClassDrawing.Box(kind: .note, frame: frame, rules: [], texts: texts)
        case .class:
            var texts = node.annotations.enumerated().map { index, annotation in
                MermaidClassDrawing.Text(
                    string: guillemets(annotation),
                    point: MermaidPoint(x: frame.midX, y: row(index, from: frame.y + padY)),
                    style: .annotation
                )
            }
            texts.append(MermaidClassDrawing.Text(
                string: node.label,
                point: MermaidPoint(
                    x: frame.midX,
                    y: row(node.annotations.count, from: frame.y + padY)
                ),
                style: .name
            ))
            let first = frame.y + line * Double(node.annotations.count + 1) + 2 * padY
            let second = first + line * Double(node.attributes.count) + 2 * padY
            for (top, members) in [(first, node.attributes), (second, node.methods)] {
                texts += members.enumerated().map { index, member in
                    MermaidClassDrawing.Text(
                        string: member.text,
                        point: MermaidPoint(x: frame.x + padX, y: row(index, from: top + padY)),
                        style: .member(isStatic: member.isStatic, isAbstract: member.isAbstract),
                        isLeading: true
                    )
                }
            }
            return MermaidClassDrawing.Box(
                kind: .class,
                frame: frame,
                rules: [first, second],
                texts: texts
            )
        }
    }

    // MARK: - Cardinalities

    private static func cardinalities(
        _ relation: MermaidClassDiagram.Relation,
        edge: MermaidBoxDrawing.Edge,
        metric: MarkdownTextMetric
    ) -> [MermaidClassDrawing.Text] {
        let points = edge.points
        guard points.count >= 2 else { return [] }
        let ends = [
            (relation.fromCardinality, points[0], points[1]),
            (relation.toCardinality, points[points.count - 1], points[points.count - 2])
        ]
        return ends.compactMap { text, end, previous in
            text.map {
                MermaidClassDrawing.Text(
                    string: $0,
                    point: beside(end: end, from: previous, text: $0, metric: metric),
                    style: .cardinality
                )
            }
        }
    }

    /// Where a cardinality sits: just outside the box along the line, and beside the line far enough
    /// to clear the marker on it, on the line's left as it runs into the box.
    static func beside(
        end: MermaidPoint,
        from previous: MermaidPoint,
        text: String,
        metric: MarkdownTextMetric
    ) -> MermaidPoint {
        let dx = end.x - previous.x
        let dy = end.y - previous.y
        let length = (dx * dx + dy * dy).squareRoot()
        guard length > 0.001 else { return end }
        let (ux, uy) = (dx / length, dy / length)
        let halfWidth = metric.width(text) / 2
        let halfHeight = metric.lineHeight / 2
        let back = abs(ux) * halfWidth + abs(uy) * halfHeight + 4
        let side = abs(uy) * halfWidth + abs(ux) * halfHeight + 8
        return MermaidPoint(x: end.x - ux * back - uy * side, y: end.y - uy * back + ux * side)
    }

    // MARK: - The canvas

    /// The drawing grown to hold every cardinality and label, and moved right or down if one reached
    /// past the top or the left, since those are placed beside a line rather than in a slot.
    private static func fitted(
        _ drawing: MermaidClassDrawing,
        metric: MarkdownTextMetric
    ) -> MermaidClassDrawing {
        let margin = spacing.margin
        var extents: [MermaidRect] = drawing.edges.flatMap { edge in
            edge.cardinalities.map { textRect($0.string, center: $0.point, metric: metric) }
                + (edge.label.map { [textRect($0, center: edge.labelCenter, metric: metric)] } ?? [])
        }
        extents += drawing.boxes.map(\.frame)
        let minX = min(extents.map(\.x).min() ?? margin, margin)
        let minY = min(extents.map(\.y).min() ?? margin, margin)
        let shift = MermaidPoint(x: margin - minX, y: margin - minY)
        let moved = shift.x == 0 && shift.y == 0 ? drawing : drawing.offset(by: shift)
        return MermaidClassDrawing(
            width: max(moved.width + shift.x, (extents.map(\.maxX).max() ?? 0) + shift.x + margin),
            height: max(moved.height + shift.y, (extents.map(\.maxY).max() ?? 0) + shift.y + margin),
            groups: moved.groups,
            boxes: moved.boxes,
            edges: moved.edges
        )
    }

    private static func textRect(_ text: String, center: MermaidPoint, metric: MarkdownTextMetric) -> MermaidRect {
        let width = metric.width(text)
        return MermaidRect(
            x: center.x - width / 2,
            y: center.y - metric.lineHeight / 2,
            width: width,
            height: metric.lineHeight
        )
    }
}

extension MermaidClassDrawing {
    /// Everything moved by `shift`, the canvas size left for the caller.
    func offset(by shift: MermaidPoint) -> MermaidClassDrawing {
        func moved(_ text: Text) -> Text {
            Text(
                string: text.string,
                point: text.point.offset(by: shift),
                style: text.style,
                isLeading: text.isLeading
            )
        }
        return MermaidClassDrawing(
            width: width,
            height: height,
            groups: groups.map { Group(frame: $0.frame.offset(by: shift), title: moved($0.title)) },
            boxes: boxes.map {
                Box(
                    kind: $0.kind,
                    frame: $0.frame.offset(by: shift),
                    rules: $0.rules.map { $0 + shift.y },
                    texts: $0.texts.map(moved)
                )
            },
            edges: edges.map {
                Edge(
                    points: $0.points.map { $0.offset(by: shift) },
                    label: $0.label,
                    labelCenter: $0.labelCenter.offset(by: shift),
                    fromEnd: $0.fromEnd,
                    toEnd: $0.toEnd,
                    isDashed: $0.isDashed,
                    isNoteLink: $0.isNoteLink,
                    isLoop: $0.isLoop,
                    cardinalities: $0.cardinalities.map(moved)
                )
            }
        )
    }
}
