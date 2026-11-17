import Foundation
import Testing

@testable import DirnexCore

/// A gantt's statements and its schedule (PLAN.md §M39 ▸ Slice 15). Where a case has a Mermaid answer,
/// it is the one Mermaid 12.3 drew on its own docs page: the bars' starts and widths there, read back
/// as dates.
@Suite("Mermaid gantt statements and schedule")
struct MermaidGanttParserTests {
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

    // MARK: - Mermaid's own examples

    @Test("the docs' first example: an after, and a task starting where the one above ends")
    func firstExample() {
        let chart = gantt("""
            title A Gantt Diagram
            dateFormat YYYY-MM-DD
            section Section
                A task          :a1, 2014-01-01, 30d
                Another task    :after a1, 20d
            section Another
                Task in Another :2014-01-12, 12d
                another task    :24d
        """)
        #expect(chart?.title == "A Gantt Diagram")
        #expect(spans(chart) == [
            "a1 2014-01-01 00:00 → 2014-01-31 00:00",
            "task1 2014-01-31 00:00 → 2014-02-20 00:00",
            "task2 2014-01-12 00:00 → 2014-01-24 00:00",
            "task3 2014-01-24 00:00 → 2014-02-17 00:00"
        ])
        #expect(chart?.tasks.map(\.section) == ["Section", "Section", "Another", "Another"])
        #expect(chart?.tasks.map(\.row) == [0, 1, 2, 3])
        #expect(
            chart?.tasks.map(\.name) == ["A task", "Another task", "Task in Another", "another task"]
        )
    }

    private static let excludesExample = """
        dateFormat  YYYY-MM-DD
        excludes    weekends
        section A section
        Completed task            :done,    des1, 2014-01-06,2014-01-08
        Active task               :active,  des2, 2014-01-09, 3d
        Future task               :         des3, after des2, 5d
        section Critical tasks
        Completed task in the critical line :crit, done, 2014-01-06,24h
        Implement parser and jison          :crit, done, after des1, 2d
        Create tests for parser             :crit, active, 3d
        Future task in critical line        :crit, 5d
        Create tests for renderer           :2d
        Add to mermaid                      :until isadded
        Functionality added                 :milestone, isadded, 2014-01-25, 0d
    """

    @Test("the docs' excludes example: weekends push a duration's end, never a date's")
    func excludesExample() {
        let chart = gantt(Self.excludesExample)
        #expect(spans(chart) == [
            "des1 2014-01-06 00:00 → 2014-01-08 00:00",
            "des2 2014-01-09 00:00 → 2014-01-14 00:00",
            "des3 2014-01-14 00:00 → 2014-01-21 00:00",
            "task1 2014-01-06 00:00 → 2014-01-07 00:00",
            "task2 2014-01-08 00:00 → 2014-01-10 00:00",
            "task3 2014-01-10 00:00 → 2014-01-15 00:00",
            "task4 2014-01-15 00:00 → 2014-01-22 00:00",
            "task5 2014-01-22 00:00 → 2014-01-24 00:00",
            // `until` is no `YYYY-MM-DD` date, so its Saturday end is pushed to Monday too.
            "task6 2014-01-24 00:00 → 2014-01-27 00:00",
            "isadded 2014-01-25 00:00 → 2014-01-25 00:00"
        ])
        let tags = chart?.tasks.map { task in
            [
                task.isActive ? "a" : "",
                task.isDone ? "d" : "",
                task.isCritical ? "c" : "",
                task.isMilestone ? "m" : ""
            ].joined()
        }
        #expect(tags == ["d", "a", "", "dc", "dc", "ac", "c", "", "", "m"])
        // Its bar stops at the milestone, as Mermaid drew it: 40 points, one day.
        #expect(day(chart?.tasks[8].drawnEnd) == "2014-01-25 00:00")
        // The weekends between the first start and the last end.
        #expect(chart?.excludedRuns.map { "\(day($0.lowerBound)) – \(day($0.upperBound))" } == [
            "2014-01-11 00:00 – 2014-01-13 00:00",
            "2014-01-18 00:00 – 2014-01-20 00:00",
            "2014-01-25 00:00 – 2014-01-27 00:00"
        ])
    }

    @Test("the bar stops before the excluded days a task's end was pushed over")
    func drawnEnd() {
        let chart = gantt("""
            dateFormat YYYY-MM-DD
            excludes weekends
            A :a, 2014-01-09, 2d
        """)
        // Thursday + 2 days ends on Saturday, pushed to Monday; the bar ends on Saturday.
        #expect(day(chart?.tasks.first?.end) == "2014-01-13 00:00")
        #expect(day(chart?.tasks.first?.drawnEnd) == "2014-01-11 00:00")
        // An end written as a `YYYY-MM-DD` date stays where it is, weekend or not.
        let dated = gantt("dateFormat YYYY-MM-DD\nexcludes weekends\nB :b, 2014-01-09, 2014-01-13")
        #expect(day(dated?.tasks.first?.end) == "2014-01-13 00:00")
        #expect(dated?.tasks.first?.drawnEnd == nil)
    }

    // MARK: - Statements

    @Test("keywords in any case; values cut at # and ;; a keyword needs a space after it")
    func statements() {
        let chart = gantt("""
            DATEFORMAT DD.MM.YYYY # day first
            AxisFormat %d %b; ignored
            tickInterval 2day
            TITLE Plan; with a semicolon
            Section One # kept
            title: x :t, 01.01.2014, 1d
            weekday Monday
            topAxis
            todayMarker stroke-width:5px,stroke:#0f0
        """, clock: Self.clock)
        #expect(chart?.title == "Plan; with a semicolon")
        #expect(chart?.axisFormat == "%d %b")
        #expect(chart?.tickInterval == .init(count: 2, unit: .day))
        #expect(chart?.tasks.map(\.name) == ["title"])
        #expect(chart?.tasks.map(\.section) == ["One # kept"])
        #expect(chart?.weekStart == 1)
        #expect(chart?.hasTopAxis == true)
        #expect(day(chart?.tasks.first?.start) == "2014-01-01 00:00")
        // A style string is not read, but it is not `off` either.
        #expect(chart?.today != nil)
    }

    @Test("todayMarker off takes the line away; no clock gives none")
    func todayMarker() {
        #expect(gantt("todayMarker off\nA :a, 2014-01-01, 1d", clock: Self.clock)?.today == nil)
        #expect(gantt("A :a, 2014-01-01, 1d")?.today == nil)
        #expect(day(gantt("A :a, 2014-01-01, 1d", clock: Self.clock)?.today) == "2026-11-15 21:00")
    }

    @Test("accessibility lines are skipped, click is named, and the axis has its defaults")
    func skippedAndNamed() {
        let chart = gantt("""
            accTitle: A title
            accDescr: One line
            accDescr {
                Two: lines
            }
            A :a, 2014-01-01, 1d
            click a href "https://example.com"
        """)
        #expect(chart?.tasks.count == 1)
        #expect(chart?.undrawn == ["click"])
        #expect(chart?.axisFormat == "%Y-%m-%d")
        #expect(gantt("dateFormat D\nA :a, 1, 1d")?.axisFormat == "%d")
        #expect(gantt("tickInterval 0day\nA :a, 2014-01-01, 1d")?.tickInterval == nil)
    }

    @Test("what Mermaid refuses falls back", arguments: [
        "title Only a title",
        "A task with no colon",
        "A :milestone",
        "A :a, b, 2014-01-01, 1d",
        "A :3d",
        "A :a, not a date, 1d",
        "dateFormat YYYY-MM-DD\nA :a, 2014-01-01, 1d\nB :done, b, 2014-01-01, 1d, x"
    ])
    func refusals(body: String) {
        #expect(MermaidParser.parse("gantt\n" + body) == .unsupported("gantt"))
    }

    @Test("excluding every day fails the chart, where Mermaid gives up after 10 000 days")
    func everyDayExcluded() {
        let body = "excludes monday tuesday wednesday thursday friday saturday sunday\nA :a, 2014-01-01, 1d"
        #expect(MermaidParser.parse("gantt\n" + body) == .unsupported("gantt"))
    }
}
