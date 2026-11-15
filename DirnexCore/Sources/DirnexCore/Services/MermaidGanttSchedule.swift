import Foundation

/// Where each task of a gantt starts and ends, worked out as Mermaid 12.3's `ganttDb` works it out
/// (PLAN.md §M39 ▸ Slice 15).
///
/// A task's data is one to three fields after any leading tags (`active`, `done`, `crit`,
/// `milestone`, `vert`): an end; a start and an end; or an id, a start and an end. A start is a date
/// in the `dateFormat`, or `after a b`, the latest end among those tasks. An end is a date, `until a
/// b`, the earliest start among them, or a duration (`3d`, `2w`, `1.5h`), and anything else gives
/// the task no length, as Mermaid does with a warning. A task with only an end starts where the
/// task above it ends.
///
/// **The passes are Mermaid's, on purpose.** It places every task in order, then again, up to
/// eleven times in all, until each has both ends, so a task can name one written below it; and a
/// pass that finds one of an `after`'s tasks placed and another not yet uses the placed one, which
/// decides what a forward reference in a list draws. Porting the loop rather than a dependency
/// sort keeps that answer. A task still unplaced after the last pass keeps its row and draws no bar.
///
/// **`excludes`** pushes the end of a task given a duration out past every excluded day it
/// covers, while the bar stops before them (`drawnEnd`). A task whose end is a `YYYY-MM-DD` date is
/// left alone, whatever the `dateFormat`.
///
/// One departure: a gantt with no `dateFormat` reads dates as `YYYY-MM-DD`, as Mermaid's docs
/// say it does. Mermaid itself hands such a date to JavaScript's `Date`, which reads `2014-01-01`
/// as midnight in London and ignores an end date entirely, giving the bar no length.
enum MermaidGanttSchedule {
    /// What makes a gantt impossible to draw, where Mermaid shows an error instead.
    enum Failure: Error, Equatable {
        /// A start that is neither a date nor an `after`.
        case invalidDate(String)
        /// Data with no field left after its tags, or more than three.
        case badData(String)
        /// A task with only an end and nothing above it to start from.
        case noPreviousTask(String)
        /// `excludes` left no day a task could end on.
        case everyDayExcluded
    }

    static func resolve(
        _ source: MermaidGanttSource,
        clock: MermaidGanttClock
    ) throws -> MermaidGantt {
        var schedule = MermaidGanttScheduler(source: source, clock: clock)
        try schedule.add(source.tasks)
        var passes = 1
        while try !schedule.pass(), passes < 11 {
            passes += 1
        }
        return schedule.gantt
    }
}
