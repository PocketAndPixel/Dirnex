import Foundation
import Testing

@testable import DirnexCore

/// A gantt's calendar, its `dateFormat` and its `axisFormat` (PLAN.md §M39 ▸ Slice 15).
@Suite("Mermaid gantt time and formats")
struct MermaidGanttTimeTests {
    private func time(_ year: Int, _ month: Int, _ day: Int, _ hour: Int = 0, _ minute: Int = 0) -> Double {
        MermaidGanttTime.time(.init(year: year, month: month, day: day, hour: hour, minute: minute))
    }

    private func date(_ time: Double) -> String {
        MermaidGanttDateFormat.format(MermaidGanttTime.fields(time), "YYYY-MM-DD HH:mm")
    }

    private let utc = TimeZone(secondsFromGMT: 0) ?? .current
    private let today = MermaidGanttTime.Fields(year: 2026, month: 11, day: 15)

    // MARK: - The calendar

    @Test("days and civil dates round-trip, leap days included")
    func civilRoundTrip() {
        for days in stride(from: -800_000, through: 800_000, by: 997) {
            let date = MermaidGanttTime.civil(days)
            #expect(MermaidGanttTime.days(year: date.year, month: date.month, day: date.day) == days)
        }
        #expect(MermaidGanttTime.days(year: 1970, month: 1, day: 1) == 0)
        #expect(MermaidGanttTime.daysInMonth(year: 2024, month: 2) == 29)
        #expect(MermaidGanttTime.daysInMonth(year: 1900, month: 2) == 28)
        #expect(MermaidGanttTime.daysInMonth(year: 2000, month: 2) == 29)
        #expect(MermaidGanttTime.Fields(year: 2014, month: 1, day: 5).weekday == 0)
        #expect(date(time(2014, 2, 30)) == "2014-03-02 00:00")
    }

    @Test("durations add as dayjs adds them", arguments: [
        (1.5, MermaidGanttTime.Unit.day, "2014-01-03 00:00"),
        (0.5, .day, "2014-01-02 00:00"),
        (2.5, .week, "2014-01-19 00:00"),
        (1.5, .month, "2014-02-28 00:00"),
        (13, .month, "2015-02-28 00:00"),
        (1, .year, "2015-01-31 00:00"),
        (90, .minute, "2014-01-01 01:30"),
        (1.5, .hour, "2014-01-01 01:30"),
        (30, .second, "2014-01-01 00:00")
    ])
    func durations(value: Double, unit: MermaidGanttTime.Unit, expected: String) {
        let start = unit == .month || unit == .year ? time(2014, 1, 31) : time(2014, 1, 1)
        #expect(date(MermaidGanttTime.adding(value, unit, to: start)) == expected)
    }

    @Test("an instant becomes the wall clock of its zone, and back")
    func instants() throws {
        let kyiv = try #require(TimeZone(identifier: "Europe/Kiev"))
        let noonUTC = Date(timeIntervalSince1970: 1_388_577_600) // 2014-01-01 12:00 UTC
        let wall = MermaidGanttTime.wallClock(noonUTC, in: kyiv)
        #expect(date(wall) == "2014-01-01 14:00")
        #expect(MermaidGanttTime.instant(wall, in: kyiv) == noonUTC)
    }

    // MARK: - dateFormat

    @Test("a strict parse reads what formatting gives back, and nothing else", arguments: [
        ("2014-01-05", "YYYY-MM-DD", "2014-01-05 00:00"),
        ("05.01.2014", "DD.MM.YYYY", "2014-01-05 00:00"),
        ("2014-01-05 13:45", "YYYY-MM-DD HH:mm", "2014-01-05 13:45"),
        ("5 Jan 14", "D MMM YY", "2014-01-05 00:00"),
        ("January 5th 2014", "MMMM Do YYYY", "2014-01-05 00:00"),
        ("Sun 2014-01-05", "ddd YYYY-MM-DD", "2014-01-05 00:00"),
        ("1/5/2014 1:30 PM", "M/D/YYYY h:mm A", "2014-01-05 13:30"),
        ("12:15 am 2014-01-05", "hh:mm a YYYY-MM-DD", "2014-01-05 00:15"),
        ("2014 Q2", "YYYY [Q]Q", "2014-04-01 00:00"),
        ("2014T10", "YYYYTHH", "2014-01-01 10:00")
    ])
    func strictParse(text: String, format: String, expected: String) throws {
        let parsed = try #require(MermaidGanttDateFormat.parse(text, format: format, today: today))
        #expect(date(MermaidGanttTime.time(parsed.fields)) == expected)
    }

    @Test("a parse that would not format back is refused", arguments: [
        ("2014-02-30", "YYYY-MM-DD"),
        ("2014-1-5", "YYYY-MM-DD"),
        ("2014-01-05 extra", "YYYY-MM-DD"),
        ("Mon 2014-01-05", "ddd YYYY-MM-DD"),
        ("2014-01-05 25:00", "YYYY-MM-DD HH:mm"),
        ("jan 2014", "MMM YYYY"),
        ("10:00:00.5", "HH:mm:ss.S"),
        ("", "YYYY-MM-DD")
    ])
    func strictRefusal(text: String, format: String) {
        #expect(MermaidGanttDateFormat.parse(text, format: format, today: today) == nil)
    }

    @Test("what a format leaves out comes from today, as dayjs takes it from new Date()")
    func partsFromToday() throws {
        let timeOnly = try #require(
            MermaidGanttDateFormat.parse("17:49", format: "HH:mm", today: today)
        )
        #expect(date(MermaidGanttTime.time(timeOnly.fields)) == "2026-11-15 17:49")
        let yearOnly = try #require(
            MermaidGanttDateFormat.parse("2014", format: "YYYY", today: today)
        )
        #expect(date(MermaidGanttTime.time(yearOnly.fields)) == "2014-01-01 00:00")
        let monthDay = try #require(
            MermaidGanttDateFormat.parse("03-04", format: "MM-DD", today: today)
        )
        #expect(date(MermaidGanttTime.time(monthDay.fields)) == "2026-03-04 00:00")
    }

    @Test("an offset is read as written")
    func offsets() throws {
        let parsed = try #require(MermaidGanttDateFormat.parse(
            "2014-01-01T10:00-05:30",
            format: "YYYY-MM-DD[T]HH:mmZ",
            today: today
        ))
        #expect(parsed.offsetMinutes == -330)
        #expect(
            MermaidGanttDateFormat.parse(
                "2014-01-01 10:00 Z",
                format: "YYYY-MM-DD HH:mm Z",
                today: today
            )?
                .offsetMinutes == 0
        )
        #expect(MermaidGanttDateFormat.format(parsed.fields, "ZZ", offsetMinutes: -330) == "-0530")
    }

    @Test("ordinals are dayjs's English ones")
    func ordinals() {
        let pairs = [
            (1, "1st"),
            (2, "2nd"),
            (3, "3rd"),
            (4, "4th"),
            (11, "11th"),
            (12, "12th"),
            (13, "13th"),
            (21, "21st"),
            (22, "22nd"),
            (23, "23rd"),
            (24, "24th"),
            (31, "31st")
        ]
        for (number, expected) in pairs {
            #expect(MermaidGanttDateFormat.ordinal(number) == expected)
        }
    }

    // MARK: - JavaScript's Date, the second chance

    @Test("an ISO start reads as JavaScript reads it, a bare date at midnight in UTC")
    func scriptDates() throws {
        let kyiv = try #require(TimeZone(identifier: "Europe/Kiev"))
        func read(_ text: String) -> String? {
            MermaidGanttScriptDate.wallClock(text, in: kyiv).map(date)
        }
        #expect(read("2014-01-01") == "2014-01-01 02:00")
        #expect(read("2014-01") == "2014-01-01 02:00")
        #expect(read("2014-01-02 10:00") == "2014-01-02 10:00")
        #expect(read("2014-01-02T10:00:30.5") == "2014-01-02 10:00")
        #expect(read("2014-01-02T10:00Z") == "2014-01-02 12:00")
        #expect(read("2014-01-02T10:00+01:00") == "2014-01-02 11:00")
        #expect(read("2014-02-30") == nil)
        #expect(read("Jan 2 2014") == nil)
        #expect(read("12014-01-01") == nil)
        #expect(read("+012014-01-01") == nil)
    }

    // MARK: - axisFormat

    @Test("d3's specifiers in English", arguments: [
        ("%Y-%m-%d", "2014-01-05"),
        ("%b %e %a", "Jan  5 Sun"),
        ("%B %-d, %A", "January 5, Sunday"),
        ("%_m/%0e", " 1/05"),
        ("%H:%M:%S.%L %p", "13:07:09.000 PM"),
        ("%I %p", "01 PM"),
        ("%j %U %W %V %u %w", "005 01 00 01 7 0"),
        ("%g %G %y %q", "14 2014 14 1"),
        ("%c", "1/5/2014, 1:07:09 PM"),
        ("%x %X", "1/5/2014 1:07:09 PM"),
        ("%Z %% %k", "+0000 % k"),
        ("%Q", "1388927229000")
    ])
    func axisFormat(specifier: String, expected: String) {
        let sunday = MermaidGanttTime.time(
            .init(year: 2014, month: 1, day: 5, hour: 13, minute: 7, second: 9)
        )
        #expect(MermaidGanttAxisFormat.format(sunday, specifier, zone: utc) == expected)
    }

    @Test("ISO weeks across a year's end, as d3 counts them")
    func isoWeeks() {
        func week(_ year: Int, _ month: Int, _ day: Int) -> String {
            MermaidGanttAxisFormat.format(time(year, month, day), "%G-W%V", zone: utc)
        }
        #expect(week(2015, 1, 1) == "2015-W01")
        #expect(week(2015, 1, 5) == "2015-W02")
        #expect(week(2016, 1, 1) == "2015-W53")
        #expect(week(2014, 12, 29) == "2015-W01")
    }
}
