import Foundation

/// A placed gantt chart, drawn (PLAN.md §M39 ▸ Slice 15).
///
/// Painted back to front: section stripes, excluded days, the grid, the bars, their names, the
/// sections' names, `vert` markers and the today line, so a line Mermaid draws over the chart is
/// over it here too. Class names only, as every diagram here is (`MermaidSVG`); the stylesheet
/// gives a bar its state's color from the page's own palette (Oleg's call when the slice opened),
/// so a chart follows light and dark like the prose around it.
enum MermaidGanttSVG {
    static func svg(_ drawing: MermaidGanttDrawing, scale: Double = 1) -> String {
        let body = drawing.bands.map { MermaidSVG.rect($0, classes: "mm-gantt-band") }.joined()
            + drawing.excluded.map { MermaidSVG.rect($0, classes: "mm-gantt-excluded") }.joined()
            + grid(drawing)
            + drawing.bars.map(bar).joined()
            + drawing.labels.map { label($0, classes: "mm-gantt-label") }.joined()
            + drawing.sections.filter { !$0.text.isEmpty }
            .map { label($0, classes: "mm-gantt-section") }.joined()
            + drawing.markers.map(marker(drawing)).joined()
            + (drawing.today.map { line(x: $0, drawing, classes: "mm-gantt-today") } ?? "")
        return MermaidSVG.document(
            width: drawing.width,
            height: drawing.height,
            body: body,
            classes: "mermaid mermaid-gantt",
            scale: scale
        )
    }

    private static func grid(_ drawing: MermaidGanttDrawing) -> String {
        drawing.ticks.map { tick in
            let grid = line(x: tick.x, drawing, classes: "mm-gantt-grid")
            guard let label = tick.label else { return grid }
            let rows = [drawing.tickLabelY] + (drawing.topTickLabelY.map { [$0] } ?? [])
            return grid + rows.map {
                MermaidSVG.text(label, at: MermaidPoint(x: tick.x, y: $0), classes: "mm-gantt-tick")
            }.joined()
        }.joined()
    }

    private static func line(x: Double, _ drawing: MermaidGanttDrawing, classes: String) -> String {
        MermaidSVG.line(
            [MermaidPoint(x: x, y: drawing.gridTop), MermaidPoint(x: x, y: drawing.axisY)],
            classes: classes
        )
    }

    private static func bar(_ bar: MermaidGanttDrawing.Bar) -> String {
        let state = bar.isActive ? "mm-gantt-active" : bar.isDone ? "mm-gantt-done" : "mm-gantt-task"
        let classes = "mm-gantt-bar " + state + (bar.isCritical ? " mm-gantt-crit" : "")
        guard bar.isMilestone else { return MermaidSVG.rect(bar.frame, classes: classes, radius: 3) }
        let frame = bar.frame
        let points = [
            MermaidPoint(x: frame.midX, y: frame.y),
            MermaidPoint(x: frame.maxX, y: frame.midY),
            MermaidPoint(x: frame.midX, y: frame.maxY),
            MermaidPoint(x: frame.x, y: frame.midY)
        ]
        let path = points
            .map { "\(MermaidSVG.number($0.x)),\(MermaidSVG.number($0.y))" }
            .joined(separator: " ")
        return "<polygon class=\"\(classes)\" points=\"\(path)\"/>"
    }

    private static func label(_ label: MermaidGanttDrawing.Label, classes: String) -> String {
        MermaidSVG.text(
            label.text,
            at: label.at,
            classes: label.isMilestone ? classes + " mm-gantt-milestone-label" : classes,
            anchor: label.anchor.rawValue
        )
    }

    private static func marker(_ drawing: MermaidGanttDrawing) -> (MermaidGanttDrawing.Marker) -> String {
        { marker in
            line(x: marker.x, drawing, classes: "mm-gantt-vert")
                + label(marker.label, classes: "mm-gantt-vert-label")
        }
    }
}
