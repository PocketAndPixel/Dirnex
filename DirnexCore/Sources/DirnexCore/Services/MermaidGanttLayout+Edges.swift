import Foundation

/// What a gantt's layout does at its edges (PLAN.md §M39 ▸ Slice 15): tick labels kept apart, a label
/// past either side given room, and the sections' runs of rows.
extension MermaidGanttLayout {
    /// A tick's label is a point smaller than the names (`QuickViewMarkdownDiagram`).
    private static let tickScale = 10.0 / 11.0
    /// The least room between two tick labels.
    private static let tickGap = 8.0

    /// Every grid line, and a label on every `k`th: the smallest `k` at which no two labels touch.
    ///
    /// A departure, and the reason is the fixed width. d3 asks for about ten ticks whatever the
    /// width, and Mermaid writes a label on each, so at a page's width of 900 points or more they
    /// fit; at this 700-point time line a two-day step's nineteen dates ran into one another.
    static func thinned(_ ticks: [MermaidGanttDrawing.Tick], metric: MarkdownTextMetric)
        -> [MermaidGanttDrawing.Tick] {
        let widths = ticks.map { metric.width($0.label ?? "") * tickScale }
        func clears(_ step: Int) -> Bool {
            for index in stride(from: 0, to: ticks.count - step, by: step) {
                let room = ticks[index + step].x - ticks[index].x
                let needed: Double = (widths[index] + widths[index + step]) / 2 + tickGap
                if room < needed { return false }
            }
            return true
        }
        let step = (1...max(1, ticks.count)).first(where: clears) ?? 1
        return ticks.enumerated().map { index, tick in
            index % step == 0 ? tick : MermaidGanttDrawing.Tick(x: tick.x, label: nil)
        }
    }

    /// The width a label past the right edge needs; one past the left edge moves everything right.
    static func widen(_ drawing: inout MermaidGanttDrawing, metric: MarkdownTextMetric) {
        let extents = drawing.labels.map { extent($0, width: metric.width($0.text)) }
            + drawing.markers.map { extent($0.label, width: metric.width($0.label.text)) }
            + drawing.ticks.compactMap { tick in
                tick.label.map {
                    extent(
                        .init(text: $0, at: .init(x: tick.x, y: 0), anchor: .middle),
                        width: metric.width($0) * tickScale
                    )
                }
            }
        let lowest = extents.map(\.lowerBound).min() ?? 0
        let highest = extents.map(\.upperBound).max() ?? 0
        if highest + margin > drawing.width { drawing.width = (highest + margin).rounded(.up) }
        if lowest < margin {
            drawing = shifted(drawing, by: (margin - lowest).rounded(.up))
        }
    }

    private static func extent(_ label: MermaidGanttDrawing.Label, width: Double) -> ClosedRange<
        Double
    > {
        switch label.anchor {
        case .start: label.at.x...(label.at.x + width)
        case .middle: (label.at.x - width / 2)...(label.at.x + width / 2)
        case .end: (label.at.x - width)...label.at.x
        }
    }

    private static func shifted(_ drawing: MermaidGanttDrawing, by shift: Double) -> MermaidGanttDrawing {
        func moved(_ rect: MermaidRect) -> MermaidRect {
            MermaidRect(x: rect.x + shift, y: rect.y, width: rect.width, height: rect.height)
        }
        func moved(_ label: MermaidGanttDrawing.Label) -> MermaidGanttDrawing.Label {
            .init(
                text: label.text,
                at: .init(x: label.at.x + shift, y: label.at.y),
                anchor: label.anchor,
                isMilestone: label.isMilestone
            )
        }
        func moved(_ bar: MermaidGanttDrawing.Bar) -> MermaidGanttDrawing.Bar {
            .init(
                frame: moved(bar.frame),
                isMilestone: bar.isMilestone,
                isActive: bar.isActive,
                isDone: bar.isDone,
                isCritical: bar.isCritical
            )
        }
        return MermaidGanttDrawing(
            width: drawing.width + shift,
            height: drawing.height,
            // A stripe still starts at the drawing's left edge, under the sections' names.
            bands: drawing.bands.map { MermaidRect(
                x: 0,
                y: $0.y,
                width: $0.width + shift,
                height: $0.height
            ) },
            excluded: drawing.excluded.map(moved),
            ticks: drawing.ticks.map { .init(x: $0.x + shift, label: $0.label) },
            gridTop: drawing.gridTop,
            axisY: drawing.axisY,
            tickLabelY: drawing.tickLabelY,
            topTickLabelY: drawing.topTickLabelY,
            bars: drawing.bars.map(moved),
            labels: drawing.labels.map(moved),
            sections: drawing.sections.map(moved),
            markers: drawing.markers.map { .init(x: $0.x + shift, label: moved($0.label)) },
            today: drawing.today.map { $0 + shift }
        )
    }

    // MARK: - Sections

    struct SectionBlock: Equatable {
        let name: String
        let firstRow: Int
        let rows: Int
        /// The section's place among the distinct names, which picks its stripe.
        let style: Int
    }

    /// Runs of rows under one section name. A name used again further down is a block of its own,
    /// with the stripe of its first use, where Mermaid would label the two as one.
    static func sectionBlocks(_ tasks: [MermaidGantt.Task]) -> [SectionBlock] {
        var names: [String] = []
        var blocks: [SectionBlock] = []
        for task in tasks {
            guard let row = task.row else { continue }
            if !names.contains(task.section) { names.append(task.section) }
            if let last = blocks.last, last.name == task.section {
                blocks[blocks.count - 1] = SectionBlock(
                    name: last.name,
                    firstRow: last.firstRow,
                    rows: last.rows + 1,
                    style: last.style
                )
            } else {
                blocks.append(SectionBlock(
                    name: task.section,
                    firstRow: row,
                    rows: 1,
                    style: names.firstIndex(of: task.section) ?? 0
                ))
            }
        }
        return blocks
    }
}
