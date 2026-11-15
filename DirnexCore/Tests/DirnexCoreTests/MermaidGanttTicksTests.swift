import Foundation
import Testing

@testable import DirnexCore

/// Where a gantt's axis puts its ticks: d3's choice of step, and a step the file names (PLAN.md §M39
/// ▸ Slice 15). The tick dates are the ones Mermaid 12.3 drew on its own docs page for the same spans.
@Suite("Mermaid gantt ticks")
struct MermaidGanttTicksTests {
    private func time(_ year: Int, _ month: Int, _ day: Int, _ hour: Int = 0) -> Double {
        MermaidGanttTime.time(.init(year: year, month: month, day: day, hour: hour))
    }

    private let utc = TimeZone(secondsFromGMT: 0) ?? .current

    private func ticks(
        _ start: Double,
        _ stop: Double,
        named: MermaidGanttTickInterval? = nil,
        weekStart: Int = 0
    ) -> [String] {
        MermaidGanttTicks.ticks(from: start, to: stop, named: named, weekStart: weekStart)
            .map { MermaidGanttAxisFormat.format($0, "%Y-%m-%d %H:%M", zone: utc) }
    }

    @Test("50 days take a tick every Sunday, as Mermaid drew its first example")
    func weekly() {
        let drawn = ticks(time(2014, 1, 1), time(2014, 2, 20))
        #expect(drawn == ["05", "12", "19", "26"].map { "2014-01-\($0) 00:00" }
            + ["02", "09", "16"].map { "2014-02-\($0) 00:00" })
    }

    @Test("22 days take every other day of the month, as Mermaid drew its excludes example")
    func everyOtherDay() {
        let drawn = ticks(time(2014, 1, 6), time(2014, 1, 28))
        #expect(drawn == stride(from: 7, through: 27, by: 2).map {
            "2014-01-\(MermaidGanttDateFormat.padded($0, 2)) 00:00"
        })
        // The step restarts with the month: the 31st, then the 1st.
        #expect(ticks(time(2014, 1, 26), time(2014, 2, 18)).contains("2014-02-01 00:00"))
        #expect(ticks(time(2014, 1, 26), time(2014, 2, 18)).contains("2014-01-31 00:00"))
    }

    @Test("109 days are still weekly; three days are six-hourly")
    func otherSpans() {
        #expect(ticks(time(2014, 1, 1), time(2014, 4, 20)).count == 16)
        #expect(ticks(time(2014, 1, 1), time(2014, 4, 20)).last == "2014-04-20 00:00")
        let hours = ticks(time(2014, 1, 1, 2), time(2014, 1, 4, 2))
        #expect(hours.first == "2014-01-01 06:00")
        #expect(hours.count == 12)
    }

    @Test("months, quarters and years")
    func longSpans() {
        let months = ticks(time(2014, 1, 15), time(2014, 11, 1))
        #expect(months.first == "2014-02-01 00:00")
        #expect(months.count == 10)
        #expect(months.last == "2014-11-01 00:00")
        let quarters = ticks(time(2014, 1, 15), time(2016, 6, 1))
        #expect(quarters.prefix(3) == ["2014-04-01 00:00", "2014-07-01 00:00", "2014-10-01 00:00"])
        let years = ticks(time(1990, 6, 1), time(2030, 1, 1))
        #expect(years == stride(from: 1995, through: 2030, by: 5).map { "\($0)-01-01 00:00" })
    }

    @Test("a named step: weeks on the file's weekday, days by the month's day, months by number")
    func namedSteps() {
        let mondays = ticks(
            time(2014, 1, 1), time(2014, 1, 31),
            named: .init(count: 1, unit: .week), weekStart: 1
        )
        #expect(mondays == ["06", "13", "20", "27"].map { "2014-01-\($0) 00:00" })
        let fortnights = ticks(
            time(2014, 1, 1),
            time(2014, 3, 1),
            named: .init(count: 2, unit: .week)
        )
        #expect(fortnights.count == 4)
        let threeDays = ticks(
            time(2014, 1, 1),
            time(2014, 1, 12),
            named: .init(count: 3, unit: .day)
        )
        #expect(threeDays == ["01", "04", "07", "10"].map { "2014-01-\($0) 00:00" })
        let twoMonths = ticks(
            time(2014, 1, 1),
            time(2014, 7, 1),
            named: .init(count: 2, unit: .month)
        )
        #expect(twoMonths == ["01", "03", "05", "07"].map { "2014-\($0)-01 00:00" })
    }

    @Test("a named step past 10 000 ticks gives way to d3's own choice, as Mermaid's does")
    func namedStepCap() {
        let named = ticks(time(2014, 1, 1), time(2014, 2, 20), named: .init(count: 1, unit: .second))
        #expect(named == ticks(time(2014, 1, 1), time(2014, 2, 20)))
    }

    @Test("a span of no length has its one tick, as d3 gives it")
    func emptySpan() {
        #expect(ticks(time(2014, 1, 1), time(2014, 1, 1)) == ["2014-01-01 00:00"])
    }
}
