import Foundation

/// An ER diagram, placed (PLAN.md §M39 ▸ Slice 14).
struct MermaidERDrawing: Equatable {
    struct Text: Equatable {
        let string: String
        /// Its center, or its left end for a table cell.
        let point: MermaidPoint
        var isLeading = false
    }

    struct Entity: Equatable {
        let frame: MermaidRect
        /// Every horizontal line across the box: under the name, then between rows.
        let rules: [Double]
        /// Where the lines between columns run, from `tableTop` to the bottom.
        let columns: [Double]
        let tableTop: Double
        /// The name, then each cell, row by row.
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
        let fromCardinality: MermaidERDiagram.Cardinality
        let toCardinality: MermaidERDiagram.Cardinality
        let isIdentifying: Bool
        let isLoop: Bool

        var start: MermaidPoint { points[0] }
        var end: MermaidPoint { points[points.count - 1] }
    }

    let width: Double
    let height: Double
    let groups: [Group]
    /// One per entity, in the diagram's order.
    let entities: [Entity]
    /// One per relationship, in the diagram's order.
    let edges: [Edge]
}

/// Placing an ER diagram (PLAN.md §M39 ▸ Slice 14): each entity sized as its table, then laid out
/// through `MermaidBoxGraph`, a subgraph taking part as a group.
enum MermaidERLayout {
    /// The rank gap holds a crow's foot and its ring, some 24 points, between a box and the label.
    static let spacing = MermaidLayered.Spacing(rankGap: 28, crossGap: 30, margin: 10)
    static let padX = 12.0
    static let padY = 8.0
    /// Above and below the name of an entity with no attributes, which Mermaid draws roomy.
    static let emptyPadY = 14.0
    static let cellPadX = 8.0
    static let cellPadY = 4.0
    static let minimumWidth = 80.0

    static func lay(out diagram: MermaidERDiagram, metric: MarkdownTextMetric) -> MermaidERDrawing {
        let order = MermaidBoxGraph.order(
            boxes: diagram.entities.count,
            groupPositions: diagram.groups.map(\.position)
        )
        let (entityAt, groupAt) = (order.boxAt, order.groupAt)
        let tables = diagram.entities.map { Table($0, metric: metric) }
        let nodes = order.items.map { item -> MermaidBoxGraph.Node in
            if item.isGroup {
                let group = diagram.groups[item.index]
                return MermaidBoxGraph.Node(
                    box: nil,
                    title: group.title,
                    parent: group.parent.map { groupAt[$0] },
                    direction: group.direction
                )
            }
            let entity = diagram.entities[item.index]
            return MermaidBoxGraph.Node(
                box: tables[item.index].size,
                title: entity.label,
                parent: entity.group.map { groupAt[$0] },
                direction: nil
            )
        }
        func node(_ endpoint: MermaidERDiagram.Endpoint) -> Int {
            switch endpoint {
            case let .entity(index): entityAt[index]
            case let .group(index): groupAt[index]
            }
        }
        let graph = MermaidBoxGraph(
            direction: diagram.direction,
            nodes: nodes,
            links: diagram.relationships.map {
                MermaidBoxGraph.Link(from: node($0.from), to: node($0.to), label: $0.label)
            }
        )
        let placed = graph.lay(metric: metric, spacing: spacing)
        return MermaidERDrawing(
            width: placed.width,
            height: placed.height,
            groups: diagram.groups.indices.map { index in
                let frame = placed.frames[groupAt[index]]
                return MermaidERDrawing.Group(
                    frame: frame,
                    title: MermaidERDrawing.Text(
                        string: diagram.groups[index].title,
                        point: placed.titleCenters[groupAt[index]] ?? frame.center
                    )
                )
            },
            entities: diagram.entities.indices.map {
                tables[$0].drawn(
                    diagram.entities[$0],
                    in: placed.frames[entityAt[$0]],
                    metric: metric
                )
            },
            edges: zip(diagram.relationships, placed.edges).map { relationship, edge in
                MermaidERDrawing.Edge(
                    points: edge.points,
                    label: relationship.label,
                    labelCenter: edge.labelCenter,
                    fromCardinality: relationship.fromCardinality,
                    toCardinality: relationship.toCardinality,
                    isIdentifying: relationship.isIdentifying,
                    isLoop: edge.isLoop
                )
            }
        )
    }

    /// An entity's table measured: which columns it has and how wide each is.
    struct Table {
        /// Each column's width: type, name, then keys and comment when any row has them.
        let columns: [Double]
        let rowHeight: Double
        let bandHeight: Double
        let size: MermaidSize

        init(_ entity: MermaidERDiagram.Entity, metric: MarkdownTextMetric) {
            let rows = entity.attributes.map(Self.cells)
            let hasComment = entity.attributes.contains { $0.comment != nil }
            let hasKeys = entity.attributes.contains { $0.keys != nil }
            let count = rows.isEmpty ? 0 : hasComment ? 4 : hasKeys ? 3 : 2
            var columns = (0..<count).map { column in
                (rows.map { metric.width($0[column]) }.max() ?? 0) + 2 * cellPadX
            }
            let title = metric.width(entity.label) + 2 * padX
            let width = max(columns.reduce(0, +), title, minimumWidth)
            if !columns.isEmpty { columns[columns.count - 1] += width - columns.reduce(0, +) }
            self.columns = columns
            rowHeight = metric.lineHeight + 2 * cellPadY
            bandHeight = metric.lineHeight + 2 * (rows.isEmpty ? emptyPadY : padY)
            size = MermaidSize(width: width, height: bandHeight + rowHeight * Double(rows.count))
        }

        /// One row's cells: the type and name always, the keys and comment columns only as far as
        /// the entity needs them, as empty cells where this row has none.
        static func cells(_ attribute: MermaidERDiagram.Attribute) -> [String] {
            [attribute.type, attribute.name, attribute.keys ?? "", attribute.comment ?? ""]
        }

        func drawn(
            _ entity: MermaidERDiagram.Entity,
            in frame: MermaidRect,
            metric: MarkdownTextMetric
        ) -> MermaidERDrawing.Entity {
            let top = frame.y + bandHeight
            var texts = [MermaidERDrawing.Text(
                string: entity.label,
                point: MermaidPoint(x: frame.midX, y: frame.y + bandHeight / 2)
            )]
            var lefts: [Double] = []
            var left = frame.x
            for width in columns {
                lefts.append(left)
                left += width
            }
            for (row, attribute) in entity.attributes.enumerated() {
                let y = top + rowHeight * (Double(row) + 0.5)
                for (column, cell) in Self.cells(attribute).prefix(columns.count).enumerated()
                    where !cell.isEmpty {
                    texts.append(MermaidERDrawing.Text(
                        string: cell,
                        point: MermaidPoint(x: lefts[column] + cellPadX, y: y),
                        isLeading: true
                    ))
                }
            }
            let rows = entity.attributes.indices.map { top + rowHeight * Double($0) }
            return MermaidERDrawing.Entity(
                frame: frame,
                rules: rows,
                columns: Array(lefts.dropFirst()),
                tableTop: top,
                texts: texts
            )
        }
    }
}

/// A placed ER diagram, drawn (PLAN.md §M39 ▸ Slice 14): subgraphs, then relationships with their
/// crow's feet and labels, then entities.
enum MermaidERSVG {
    static func svg(_ drawing: MermaidERDrawing, scale: Double = 1) -> String {
        let groups = drawing.groups.map { group in
            MermaidSVG.rect(group.frame, classes: "mm-group", radius: 4)
                + MermaidSVG.text(
                    group.title.string,
                    at: group.title.point,
                    classes: "mm-group-label"
                )
        }
        let body = groups.joined() + drawing.edges.map(edge).joined() + drawing.entities.map(entity).joined(
        )
        return MermaidSVG.document(
            width: drawing.width,
            height: drawing.height,
            body: body,
            classes: "mermaid mermaid-er",
            scale: scale
        )
    }

    private static func entity(_ entity: MermaidERDrawing.Entity) -> String {
        let frame = entity.frame
        let rules = entity.rules.map {
            MermaidSVG.line(
                [MermaidPoint(x: frame.x, y: $0), MermaidPoint(x: frame.maxX, y: $0)],
                classes: "mm-box-rule"
            )
        }
        let columns = entity.columns.map {
            MermaidSVG.line(
                [MermaidPoint(x: $0, y: entity.tableTop), MermaidPoint(x: $0, y: frame.maxY)],
                classes: "mm-box-rule"
            )
        }
        let texts = entity.texts.map {
            MermaidSVG.text(
                $0.string,
                at: $0.point,
                classes: "mm-label",
                anchor: $0.isLeading ? "start" : "middle"
            )
        }
        return MermaidSVG.rect(frame, classes: "mm-node") + (rules + columns + texts).joined()
    }

    private static func edge(_ edge: MermaidERDrawing.Edge) -> String {
        let points = edge.points
        var parts = [MermaidSVG.line(
            points,
            classes: "mm-edge " + (edge.isIdentifying ? "mm-edge-solid" : "mm-edge-dotted")
        )]
        if points.count >= 2 {
            parts.append(
                MermaidMarker.erEnd(edge.toCardinality, at: edge.end, from: points[points.count - 2])
            )
            parts.append(MermaidMarker.erEnd(edge.fromCardinality, at: edge.start, from: points[1]))
        }
        if let label = edge.label {
            parts.append(MermaidSVG.edgeLabel(label, at: edge.labelCenter, plated: !edge.isLoop))
        }
        return parts.joined()
    }
}
