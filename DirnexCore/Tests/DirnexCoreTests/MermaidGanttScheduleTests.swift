import Foundation
import Testing

@testable import DirnexCore

/// A gantt's tags, references, dates and excluded days (PLAN.md §M39 ▸ Slice 15), each rule as
/// Mermaid 12.3's `ganttDb` applies it.
@Suite("Mermaid gantt schedule")
struct MermaidGanttScheduleTests {
    private static let kyiv = TimeZone(identifier: "Europe/Kiev") ?? .current

    /// 2026-11-15 21:00 in Kyiv.
    private static let clock = MermaidGanttClock(
        now: Date(timeIntervalSince1970: 1_794_769_200),
        timeZone: kyiv
    )

    private func gantt(_ body: String, clock: MermaidGanttClock = .none) -> MermaidGantt? {
        guard case let .gantt(gantt) = MermaidParser.parse("gantt\n" + body, clock: clock) else { return nil }
        return gantt
    }

    private func day(_ time: Double?) -> String {
        guard let time else { return "-" }
        return MermaidGanttDateFormat.format(MermaidGanttTime.fields(time), "YYYY-MM-DD HH:mm")
    }

    private func spans(_ gantt: MermaidGantt?) -> [String] {
        (gantt?.tasks ?? []).map { "\($0.id) \(day($0.start)) → \(day($0.end))" }
    }

    // MARK: - Tags, ids and references

    @Test("tags lead the data in any order; a tag later on is a field")
    func tags() {
        let chart = gantt("""
            A :milestone, crit, done, active, a, 2014-01-01, 1d
            B :vert, v, 2014-01-02, 0d
            C :c, 2014-01-03, 1d
        """)
        let first = chart?.tasks.first
        #expect(first?.isMilestone == true && first?.isCritical == true)
        #expect(first?.isDone == true && first?.isActive == true)
        #expect(chart?.tasks.map(\.row) == [0, nil, 1])
        #expect(chart?.tasks[1].isVertical == true)
        #expect(MermaidParser.parse("gantt\nA :a, done, 2014-01-01, 1d") == .unsupported("gantt"))
    }

    @Test("after takes the latest end, until the earliest start, and both may look ahead")
    func references() {
        let chart = gantt("""
            A :a, 2014-01-01, 3d
            B :b, 2014-01-02, 5d
            C :c, after a b, 1d
            D :d, 2014-01-01, until b e
            E :e, after f, 1d
            F :f, 2014-01-10, 1d
        """)
        #expect(spans(chart) == [
            "a 2014-01-01 00:00 → 2014-01-04 00:00",
            "b 2014-01-02 00:00 → 2014-01-07 00:00",
            "c 2014-01-07 00:00 → 2014-01-08 00:00",
            "d 2014-01-01 00:00 → 2014-01-02 00:00",
            "e 2014-01-11 00:00 → 2014-01-12 00:00",
            "f 2014-01-10 00:00 → 2014-01-11 00:00"
        ])
    }

    @Test("an after list naming a task below uses what one pass has placed, as Mermaid's does")
    func partialForwardList() {
        let chart = gantt("""
            A :a, 2014-01-01, 1d
            C :c, after a b, 1d
            B :b, 2014-01-10, 1d
        """)
        // B ends later, but it is not placed when C is, and C is placed in that same pass.
        #expect(day(chart?.tasks[1].start) == "2014-01-02 00:00")
    }

    @Test("a reference to no task is today's midnight with a clock, and no bar without")
    func unknownReference() {
        let body = "A :a, 2014-01-01, 1d\nB :b, after nope, 1d\nC :c, 2014-01-01, until nope"
        let clocked = gantt(body, clock: Self.clock)
        #expect(day(clocked?.tasks[1].start) == "2026-11-15 00:00")
        #expect(day(clocked?.tasks[2].end) == "2026-11-15 00:00")
        let plain = gantt(body)
        #expect(plain?.tasks[1].start == nil)
        #expect(plain?.tasks[1].row == 1)
        #expect(plain?.tasks[2].end == nil)
    }

    @Test("a cycle of afters leaves both rows empty and the rest drawn")
    func cycle() {
        let chart = gantt("A :a, 2014-01-01, 1d\nB :b, after c, 1d\nC :c, after b, 1d")
        #expect(chart?.tasks.map { $0.start == nil } == [false, true, true])
    }

    @Test("automatic ids count only the tasks that have none")
    func automaticIds() {
        let chart = gantt("A :2014-01-01, 1d\nB :b, 2014-01-01, 1d\nC :1d")
        #expect(chart?.tasks.map(\.id) == ["task1", "b", "task2"])
    }

    // MARK: - Dates and durations

    @Test("an end may be a date, inclusive or not, or a duration; anything else is no length")
    func ends() {
        let chart = gantt("""
            A :a, 2014-01-01, 2014-01-03
            B :b, 2014-01-01, 1.5d
            C :c, 2014-01-01, 90m
            D :d, 2014-01-31, 1M
            E :e, 2014-01-01, soon
        """)
        #expect(spans(chart).map { String($0.suffix(16)) } == [
            "2014-01-03 00:00", "2014-01-03 00:00", "2014-01-01 01:30", "2014-02-28 00:00",
            "2014-01-01 00:00"
        ])
        let inclusive = gantt("inclusiveEndDates\nA :a, 2014-01-01, 2014-01-03")
        #expect(day(inclusive?.tasks.first?.end) == "2014-01-04 00:00")
    }

    @Test("a start that the dateFormat refuses gets JavaScript's reading")
    func scriptFallback() {
        let chart = gantt("""
            dateFormat YYYY-MM-DD
            A :a, 2014-01-02 10:00, 2h
            B :b, 2014-01-02T10:00Z, 1h
        """, clock: Self.clock)
        #expect(day(chart?.tasks[0].start) == "2014-01-02 10:00")
        #expect(day(chart?.tasks[1].start) == "2014-01-02 12:00")
        let dayFirst = gantt("dateFormat DD.MM.YYYY\nA :a, 2014-01-02, 1d", clock: Self.clock)
        #expect(day(dayFirst?.tasks[0].start) == "2014-01-02 02:00")
    }

    @Test("a time-only format falls on today, as dayjs puts it")
    func timeOnly() {
        let chart = gantt("dateFormat HH:mm\nA :milestone, m1, 17:49, 2m\nB :10m", clock: Self.clock)
        #expect(spans(chart) == [
            "m1 2026-11-15 17:49 → 2026-11-15 17:51",
            "task1 2026-11-15 17:51 → 2026-11-15 18:01"
        ])
    }

    @Test("Unix milliseconds under the x format, read in the clock's zone")
    func timestamps() {
        let chart = gantt("dateFormat x\nA :a, 1388534400000, 1d", clock: Self.clock)
        #expect(day(chart?.tasks.first?.start) == "2014-01-01 02:00")
    }

    // MARK: - Excluded days

    @Test("weekday names, dates in either spelling, includes, and a Friday weekend")
    func excludes() {
        let chart = gantt("""
            dateFormat DD.MM.YYYY
            excludes Monday, 07.01.2014
            excludes 2014-01-08
            includes 13.01.2014
            A :a, 05.01.2014, 3d
            B :b, 12.01.2014, 2d
        """)
        // Sunday + 3: Monday, Tuesday and Wednesday are out, so it ends on Saturday.
        #expect(day(chart?.tasks[0].end) == "2014-01-11 00:00")
        // The Monday after is included again.
        #expect(day(chart?.tasks[1].end) == "2014-01-14 00:00")
        let friday = gantt("weekend friday\nexcludes weekends\nA :a, 2014-01-09, 1d")
        // Thursday + 1 ends on Friday; Friday and Saturday are out, so it ends on Sunday.
        #expect(day(friday?.tasks[0].end) == "2014-01-12 00:00")
    }

    @Test("a run still open at the end is shaded; none is over more than five years")
    func excludedRunEdges() {
        // Mermaid's loop forgets a run that reaches the last end; this one is shaded.
        let saturday = gantt("excludes weekends\nA :a, 2014-01-09, 2014-01-11")
        #expect(saturday?.excludedRuns.map { "\(day($0.lowerBound)) – \(day($0.upperBound))" } == [
            "2014-01-11 00:00 – 2014-01-12 00:00"
        ])
        let long = gantt("excludes weekends\nA :a, 2014-01-01, 2020-06-01")
        #expect(long?.excludedRuns.isEmpty == true)
    }
}
