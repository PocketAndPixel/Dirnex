import Foundation

/// A gantt chart, its dates resolved (PLAN.md §M39 ▸ Slice 15).
///
/// Every time here is a wall clock (`MermaidGanttTime`). Tasks keep the order the file wrote them
/// in, which is the order of the rows: Mermaid sorts by start only to decide what is painted over
/// what, never where a row goes.
struct MermaidGantt: Equatable {
    struct Task: Equatable {
        let name: String
        let id: String
        /// The `section` the task was written under, `""` before the first one.
        let section: String
        /// Top to bottom, from 0; `nil` for a `vert` marker, which takes no row.
        let row: Int?
        /// `nil` when Mermaid could not place it either (a cycle of `after`s, or a reference to a
        /// task that is not there with no clock to fall back on): the row stays, empty.
        let start: Double?
        let end: Double?
        /// Where the bar stops being drawn, when `excludes` pushed the end past excluded days: the
        /// bar ends before them and the next task starts after (`MermaidGanttSchedule`).
        let drawnEnd: Double?
        let isActive: Bool
        let isDone: Bool
        let isCritical: Bool
        let isMilestone: Bool
        let isVertical: Bool
    }

    /// The `title` statement, which Mermaid draws in place of a front matter `title`.
    let title: String?
    let tasks: [MermaidGantt.Task]
    /// d3's `strftime`-style spelling of a tick's label (`MermaidGanttAxisFormat`).
    let axisFormat: String
    let tickInterval: MermaidGanttTickInterval?
    /// The day a `week` tick falls on, 0 for Sunday.
    let weekStart: Int
    /// `topAxis`: the dates are written above the chart as well as below it.
    let hasTopAxis: Bool
    /// The days `excludes` takes out, as runs from one midnight to the midnight after the last.
    let excludedRuns: [ClosedRange<Double>]
    /// Now, when the today line is drawn: the clock gave one and `todayMarker off` did not say no.
    let today: Double?
    /// Constructs read and not drawn (`click`), named in the caption.
    let undrawn: [String]
}

/// A gantt axis's tick spacing, when the file names one (`tickInterval 1week`).
struct MermaidGanttTickInterval: Equatable {
    enum Unit: String, CaseIterable {
        case millisecond, second, minute, hour, day, week, month
    }

    let count: Int
    let unit: Unit
}

/// Today, for a gantt: the line it draws, the date a task with no year or month falls on, and where
/// Mermaid puts a task whose `after` names no task (PLAN.md §M39 ▸ Slice 15).
///
/// Passed in rather than read from `Date()`, so a render depends only on what it is handed. With no
/// clock (`none`, every test's default) there is no today line, a date with no year is in 1970, and
/// a task waiting on a task that is not there stays unplaced.
struct MermaidGanttClock {
    let now: Date?
    let timeZone: TimeZone

    static let none = MermaidGanttClock(now: nil, timeZone: TimeZone(secondsFromGMT: 0) ?? .current)

    /// The wall clock now shows, in `timeZone`.
    var wallClock: Double? {
        now.map { MermaidGanttTime.wallClock($0, in: timeZone) }
    }

    /// The fields a date that names no year, month or day takes them from.
    var today: MermaidGanttTime.Fields {
        wallClock.map(MermaidGanttTime.fields) ?? MermaidGanttTime.Fields(
            year: 1970,
            month: 1,
            day: 1
        )
    }
}
