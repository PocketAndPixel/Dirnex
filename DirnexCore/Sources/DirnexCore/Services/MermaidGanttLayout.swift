import Foundation

/// A placed gantt chart (PLAN.md §M39 ▸ Slice 15). Every `x` is from the left of the drawing.
struct MermaidGanttDrawing: Equatable {
    enum Anchor: String {
        case start
        case middle
        case end
    }

    struct Bar: Equatable {
        let frame: MermaidRect
        let isMilestone: Bool
        let isActive: Bool
        let isDone: Bool
        let isCritical: Bool
    }

    struct Label: Equatable {
        let text: String
        let at: MermaidPoint
        let anchor: Anchor
        var isMilestone = false
    }

    struct Tick: Equatable {
        let x: Double
        /// `nil` on a grid line whose label would touch its neighbor's (`MermaidGanttLayout`).
        let label: String?
    }

    struct Marker: Equatable {
        let x: Double
        let label: Label
    }

    var width: Double
    let height: Double
    /// The section stripes, one a row, on every other section.
    let bands: [MermaidRect]
    let excluded: [MermaidRect]
    let ticks: [Tick]
    /// Where the grid's lines start, and the axis they end on.
    let gridTop: Double
    let axisY: Double
    /// The labels' centre lines under the axis, and over the chart when `topAxis` asks.
    let tickLabelY: Double
    let topTickLabelY: Double?
    /// In the order they are painted: by start, as Mermaid paints them.
    let bars: [Bar]
    let labels: [Label]
    let sections: [Label]
    let markers: [Marker]
    let today: Double?
}

/// Where a gantt's rows, bars, labels and ticks go (PLAN.md §M39 ▸ Slice 15).
///
/// Mermaid's own geometry, at a width of our choosing: Mermaid takes the page's width when it
/// draws, and the preview draws a diagram once, so the time line is **700 points** wide and the
/// drawing is shrunk to fit a narrow pane like every other diagram (Oleg's call when the slice
/// opened). Rows are Mermaid's 20-point bars with a 4-point gap, in the order the file wrote the
/// tasks; the sections' column is Mermaid's 75 points, widened to its longest name, where Mermaid
/// lets a long name run under the bars.
///
/// A task's name sits in its bar when it fits, after the bar when it does not, and before the bar
/// when after would run more than half the right margin past the time line, Mermaid's own test. A
/// milestone is a diamond at the middle of its start and end, measured as a 20-point bar for that
/// test. Anything that still runs past either edge widens the drawing, where Mermaid would cut it.
enum MermaidGanttLayout {
    static let timelineWidth = 700.0
    static let barHeight = 20.0
    static let rowPitch = 24.0
    static let sectionColumn = 75.0
    static let rightMargin = 75.0
    static let margin = 4.0
    /// Mermaid's grid starts 15 points above the first bar.
    static let gridLead = 15.0
    static let tickLabelHeight = 16.0
    /// A milestone's half-diagonal: Mermaid's 20-point square turned 45° and scaled by 0.8.
    static let milestoneRadius = 0.8 * barHeight * 2.0.squareRoot() / 2

    static func lay(
        out gantt: MermaidGantt,
        metric: MarkdownTextMetric,
        zone: TimeZone = MermaidGanttClock.none.timeZone
    ) -> MermaidGanttDrawing {
        let grid = Grid(gantt, metric: metric)
        let placed = gantt.tasks.compactMap { grid.place($0) }
            // A stable sort by start, as Mermaid's `taskArray.sort` paints them.
            .enumerated()
            .sorted { ($0.element.start, $0.offset) < ($1.element.start, $1.offset) }
            .map(\.element)
        let markers = gantt.tasks.compactMap { grid.marker($0) }
        let ticks = MermaidGanttTicks.ticks(
            from: grid.scale.start,
            to: grid.scale.stop,
            named: gantt.tickInterval,
            weekStart: gantt.weekStart
        ).map {
            MermaidGanttDrawing.Tick(
                x: grid.left + grid.scale.x($0),
                label: MermaidGanttAxisFormat.format($0, gantt.axisFormat, zone: zone)
            )
        }
        let today = gantt.today.flatMap { now in
            now >= grid.scale.start && now <= grid.scale.stop ? grid.left + grid.scale.x(now) : nil
        }
        var drawing = MermaidGanttDrawing(
            width: grid.left + timelineWidth + rightMargin,
            height: grid.axisY + tickLabelHeight + margin + (markers.isEmpty ? 0 : tickLabelHeight),
            bands: grid.bands,
            excluded: gantt.excludedRuns.compactMap(grid.excluded),
            ticks: thinned(ticks, metric: metric),
            gridTop: grid.gridTop,
            axisY: grid.axisY,
            tickLabelY: grid.axisY + tickLabelHeight / 2 + 2,
            topTickLabelY: gantt.hasTopAxis ? grid.gridTop - tickLabelHeight / 2 : nil,
            bars: placed.map(\.bar),
            labels: placed.map(\.label),
            sections: grid.sectionLabels,
            markers: markers,
            today: today
        )
        widen(&drawing, metric: metric)
        return drawing
    }

    /// A task's bar and name, with the start that orders their painting.
    struct Placed {
        let start: Double
        let bar: MermaidGanttDrawing.Bar
        let label: MermaidGanttDrawing.Label
    }

    /// The chart's frame: the sections' column, the rows, the axis and the time scale.
    struct Grid {
        let metric: MarkdownTextMetric
        let blocks: [SectionBlock]
        let left: Double
        let gridTop: Double
        let rowsTop: Double
        let axisY: Double
        let scale: Scale

        init(_ gantt: MermaidGantt, metric: MarkdownTextMetric) {
            self.metric = metric
            blocks = sectionBlocks(gantt.tasks)
            let longest = blocks.flatMap { MermaidText.lines($0.name) }.map(metric.width).max() ?? 0
            left = max(sectionColumn, (10 + longest + 10).rounded(.up))
            gridTop = margin + (gantt.hasTopAxis ? tickLabelHeight : 0)
            rowsTop = gridTop + gridLead
            axisY = rowsTop + Double(gantt.tasks.filter { $0.row != nil }.count) * rowPitch
            let first = gantt.tasks.compactMap(\.start).min() ?? 0
            let last = gantt.tasks.compactMap(\.end).max() ?? first
            scale = Scale(start: first, stop: last, width: timelineWidth)
        }

        func place(_ task: MermaidGantt.Task) -> Placed? {
            guard !task.isVertical, let row = task.row, let start = task.start, let end = task.end else {
                return nil
            }
            var from = scale.x(start)
            var to = max(from, scale.x(task.drawnEnd ?? end))
            if task.isMilestone {
                let middle = from + (scale.x(end) - from) / 2
                from = middle - barHeight / 2
                to = middle + barHeight / 2
            }
            let center = rowsTop + Double(row) * rowPitch + barHeight / 2
            let frame = task.isMilestone
                ? MermaidRect(
                    x: left + (from + to) / 2 - milestoneRadius,
                    y: center - milestoneRadius,
                    width: 2 * milestoneRadius,
                    height: 2 * milestoneRadius
                )
                : MermaidRect(
                    x: left + from,
                    y: center - barHeight / 2,
                    width: to - from,
                    height: barHeight
                )
            let bar = MermaidGanttDrawing.Bar(
                frame: frame,
                isMilestone: task.isMilestone,
                isActive: task.isActive,
                isDone: task.isDone,
                isCritical: task.isCritical
            )
            return Placed(start: start, bar: bar, label: label(task, from: from, to: to, y: center))
        }

        /// Mermaid's placement of a task's name: in the bar, after it, or before it.
        private func label(_ task: MermaidGantt.Task, from: Double, to: Double, y: Double)
            -> MermaidGanttDrawing.Label {
            let width = metric.width(task.name)
            let x: Double
            let anchor: MermaidGanttDrawing.Anchor
            if width <= to - from {
                (x, anchor) = (left + (from + to) / 2, .middle)
            } else if to + width > timelineWidth + rightMargin / 2 {
                (x, anchor) = (left + from - 5, .end)
            } else {
                (x, anchor) = (left + to + 5, .start)
            }
            return MermaidGanttDrawing.Label(
                text: task.name,
                at: MermaidPoint(x: x, y: y),
                anchor: anchor,
                isMilestone: task.isMilestone
            )
        }

        func marker(_ task: MermaidGantt.Task) -> MermaidGanttDrawing.Marker? {
            guard task.isVertical, let start = task.start else { return nil }
            let x = left + scale.x(start)
            let at = MermaidPoint(x: x, y: axisY + tickLabelHeight + 10)
            return MermaidGanttDrawing.Marker(
                x: x,
                label: .init(text: task.name, at: at, anchor: .middle)
            )
        }

        func excluded(_ run: ClosedRange<Double>) -> MermaidRect? {
            let from = max(0, scale.x(run.lowerBound))
            let to = min(timelineWidth, scale.x(run.upperBound))
            guard to > from else { return nil }
            return MermaidRect(x: left + from, y: gridTop, width: to - from, height: axisY - gridTop)
        }

        var bands: [MermaidRect] {
            blocks.filter { $0.style % 2 == 0 }.flatMap { block in
                (block.firstRow..<block.firstRow + block.rows).map {
                    MermaidRect(
                        x: 0,
                        y: rowsTop + Double($0) * rowPitch - 2,
                        width: left + timelineWidth + rightMargin / 2,
                        height: rowPitch
                    )
                }
            }
        }

        var sectionLabels: [MermaidGanttDrawing.Label] {
            blocks.flatMap { block -> [MermaidGanttDrawing.Label] in
                let lines = MermaidText.lines(block.name)
                let middle = rowsTop - 2 + (Double(block.firstRow) + Double(block.rows) / 2) * rowPitch
                let top = middle - Double(lines.count - 1) * metric.lineHeight / 2
                return lines.enumerated().map { index, line in
                    MermaidGanttDrawing.Label(
                        text: line,
                        at: MermaidPoint(x: 10, y: top + Double(index) * metric.lineHeight),
                        anchor: .start
                    )
                }
            }
        }
    }

    /// d3's `scaleTime().rangeRound([0, width])`: whole points, and a chart with no length draws
    /// everything at its middle.
    struct Scale {
        let start: Double
        let stop: Double
        let width: Double

        func x(_ time: Double) -> Double {
            guard stop > start else { return (width / 2).rounded() }
            return ((time - start) / (stop - start) * width).rounded()
        }
    }
}
