import AppKit

/// The rules a gantt chart is drawn with (PLAN.md §M39 ▸ Slice 15).
///
/// Mermaid colors a bar by its state, and Oleg's call when the slice opened was to keep that with
/// the page's own colors rather than Mermaid's: a task in the link blue, an active one lighter, a
/// finished one grey, a critical one outlined in the alerts' red (with a red fill when it is
/// neither active nor done), a `vert` marker in the alerts' purple and the today line in red. Each
/// fill is its color mixed into the page background, so a bar is light on a light page and dark on
/// a dark one, and the name drawn on it keeps the text color: `ganttFills` is the table the
/// contrast test holds to 4.5:1 in both appearances (`QuickViewMarkdownGanttTests`).
enum QuickViewMarkdownGantt {
    /// A state's fill: `ink`, a custom property the page defines in both appearances, as `percent`
    /// of a mix with `--background`.
    struct Fill {
        let selector: String
        let ink: String
        let percent: Int
    }

    static let fills = [
        Fill(selector: ".mm-gantt-task", ink: "--link", percent: 25),
        Fill(selector: ".mm-gantt-active", ink: "--link", percent: 10),
        Fill(selector: ".mm-gantt-done", ink: "--muted", percent: 30),
        Fill(selector: ".mm-gantt-task.mm-gantt-crit", ink: "--alert-caution", percent: 25)
    ]

    /// The tick labels are a point smaller than the names, which `MermaidGanttLayout` assumes when
    /// it spaces them.
    static var rules: String {
        let size = QuickViewMarkdownDiagram.labelSize
        let fillRules = fills.map {
            "\($0.selector) { fill: color-mix(in srgb, var(\($0.ink)) \($0.percent)%, var(--background)); }"
        }
        return """
        .mm-gantt-band { fill: var(--code-fill); }
        .mm-gantt-excluded { fill: var(--faint); opacity: 0.22; }
        .mm-gantt-grid { stroke: var(--rule); stroke-width: 1; shape-rendering: crispEdges; }
        .mm-gantt-tick { fill: var(--muted); font-size: \(size - 1)px; }
        .mm-gantt-bar { stroke-width: 1.2; }
        .mm-gantt-task, .mm-gantt-active { stroke: var(--link); }
        .mm-gantt-done { stroke: var(--muted); }
        .mm-gantt-crit { stroke: var(--alert-caution); stroke-width: 2; }
        \(fillRules.joined(separator: "\n"))
        .mm-gantt-label, .mm-gantt-section { fill: currentColor; font-size: \(size)px; }
        .mm-gantt-milestone-label { font-style: italic; }
        .mm-gantt-today { stroke: var(--alert-caution); stroke-width: 2; }
        .mm-gantt-vert { stroke: var(--alert-important); stroke-width: 1.6; }
        .mm-gantt-vert-label { fill: var(--alert-important); font-size: \(size)px; }
        """
    }
}
